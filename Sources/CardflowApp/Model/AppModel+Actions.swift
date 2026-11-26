import Foundation
import AppKit
import UniformTypeIdentifiers
import OffloadKit

/// Ações pedidas por menu, barra de ferramentas ou barra lateral que abrem painéis do sistema ou mexem
/// nos modelos. Ficam no modelo pra menu e tela chamarem a mesma coisa.
extension AppModel {
    /// Escolher uma pasta qualquer como destino (vira o principal).
    func requestAddDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "panel.addDestination.prompt")
        panel.message = String(localized: "panel.addDestination.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addDestinationFolder(url)
    }

    func addDestinationFolder(_ rawURL: URL) {
        let url = Self.normalizeFolderURL(rawURL)
        if let mountedVol = watcher.volumes.first(where: { Self.normalizeFolderURL($0.url).path == url.path }) {
            // Se o volume escolhido estava classificado como cartão, passa a ser destino.
            if isSource(mountedVol) {
                forcedSources.remove(mountedVol.id)
                forcedDestinations.insert(mountedVol.id)
            }
        } else if !customFolders.contains(where: { $0.path == url.path })
                    && !internalShortcuts().contains(where: { $0.url.path == url.path }) {
            customFolders.append(url)
            // Garante disponibilidade imediata mesmo antes do refresh em background concluir.
            if !resolvedCustomFolders.contains(where: { $0.url.path == url.path }) {
                resolvedCustomFolders.append(ExternalVolume(url: url, name: url.lastPathComponent,
                                                            isRemovable: false, isInternal: true,
                                                            totalBytes: nil, physicalDeviceID: nil, volumeUUID: nil,
                                                            isInternalShortcut: true))
            }
        }
        setUserDestination(url)
        selection = .destination(url)
    }

    /// Tira uma pasta da lista de destinos lembrados (não apaga nada do disco).
    func forgetDestinationFolder(_ rawURL: URL) {
        let path = Self.normalizeFolderURL(rawURL).path
        customFolders.removeAll { $0.path == path }
        resolvedCustomFolders.removeAll { $0.url.path == path }
        if let d = destinationURL, Self.normalizeFolderURL(d).path == path { destinationURL = nil; preferredDestUUID = nil }
        if let b = backupURL, Self.normalizeFolderURL(b).path == path { backupURL = nil; preferredBackupUUID = nil }
        reconcileVolumes()
        saveDiskSelection()
    }

    func setBackup(_ rawURL: URL?) {
        let url = rawURL.map(Self.normalizeFolderURL)
        backupURL = url
        preferredBackupUUID = volume(url)?.volumeUUID
        if let url, let dest = destinationURL, Self.normalizeFolderURL(dest).path == url.path {
            destinationURL = nil
            preferredDestUUID = nil
        }
        reconcileVolumes()
        saveDiskSelection()
    }

    enum DestinationRole { case principal, backup, none }
    func role(of url: URL) -> DestinationRole {
        let path = Self.normalizeFolderURL(url).path
        if let d = destinationURL, Self.normalizeFolderURL(d).path == path { return .principal }
        if let b = backupURL, Self.normalizeFolderURL(b).path == path { return .backup }
        return .none
    }
    func setRole(_ role: DestinationRole, for rawURL: URL) {
        let url = Self.normalizeFolderURL(rawURL)
        switch role {
        case .principal:
            if let b = backupURL, Self.normalizeFolderURL(b).path == url.path {
                backupURL = nil; preferredBackupUUID = nil
            }
            setUserDestination(url)
        case .backup:
            setBackup(url)
        case .none:
            if let d = destinationURL, Self.normalizeFolderURL(d).path == url.path {
                destinationURL = nil; preferredDestUUID = nil
            }
            if let b = backupURL, Self.normalizeFolderURL(b).path == url.path {
                backupURL = nil; preferredBackupUUID = nil
            }
            reconcileVolumes(); saveDiskSelection()
        }
    }

    // MARK: Modelos

    func requestImportModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let cfp = UTType(filenameExtension: "cfp") { panel.allowedContentTypes = [cfp, .json] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = presetStore
        Task.detached { [weak self] in
            do {
                var p = try store.load(from: url)
                let existing = Set(((try? store.list()) ?? []).map(\.id))
                if p.id == "factory-default" || p.id == "flat-default" || existing.contains(p.id) {
                    p.id = UUID().uuidString
                }
                try store.save(p)
                let savedID = p.id
                await MainActor.run { [weak self] in
                    self?.reloadPresets(selecting: savedID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.modelError = String(localized: "main.importError")
                }
            }
        }
    }

    func requestExportModel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetStore.exportFilename(for: activePreset)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preset = activePreset
        let store = presetStore
        Task.detached { [weak self] in
            do {
                try store.export(preset, to: url)
            } catch {
                await MainActor.run { [weak self] in
                    self?.modelError = error.localizedDescription
                }
            }
        }
    }

    /// Novo modelo a partir do de fábrica, já salvo e selecionado; o painel do modelo abre pra editar.
    func requestNewModel() {
        var p = Preset.factoryDefault
        p.id = UUID().uuidString
        p.name = uniqueModelName(String(localized: "model.new.defaultName"))
        do {
            try presetStore.save(p)
        } catch {
            modelError = error.localizedDescription
            return
        }
        reloadPresets(selecting: p.id, preserveContext: true)
        savePresetSelection()
        setInspector(true)
    }

    func uniqueModelName(_ base: String) -> String {
        let names = Set(presets.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Nome de exibição: o de fábrica sai localizado; os do usuário ficam como foram escritos.
    func displayName(_ p: Preset) -> String {
        p.id == Preset.factoryDefault.id ? String(localized: "preset.factory.name") : p.name
    }
}

// MARK: - Painel do modelo (edição ao vivo)

extension AppModel {
    /// Editor do modelo ativo pro painel lateral. Preserva rascunho em andamento se o inspetor foi fechado e reaberto.
    func makeLiveEditor() -> PresetEditorModel {
        let restoring: Preset?
        if let override = previewPresetOverride,
           (isFactory(selectedPresetId) || override.id == activePreset.id) {
            restoring = override
        } else {
            restoring = nil
        }
        let ed = PresetEditorModel.editing(activePreset, restoringDraft: restoring)
        ed.otherNames = Set(presets.filter { $0.id != ed.draft.id }.map(\.name))
        return ed
    }

    /// Cada mudança no painel: a prévia mostra na hora; um modelo do usuário é salvo sozinho depois de
    /// uma pausa curta (em background). O de fábrica só vira modelo quando o usuário salva com um nome.
    func applyLiveDraft(_ editor: PresetEditorModel) {
        guard editor.hasUnsavedChanges else {
            liveSaveTask?.cancel()
            liveSaveTask = nil
            if previewPresetOverride != nil { previewPresetOverride = nil; recomputeAllPreviews() }
            return
        }
        previewPresetOverride = editor.draft
        recomputeAllPreviews()
        guard !editor.isNew else { return }
        liveSaveTask?.cancel()
        let store = presetStore
        liveSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, editor.canSave else { return }
            let normalized = editor.normalizedForSave()
            let savedList: [Preset]? = await Task.detached {
                do {
                    try store.save(normalized)
                    return (try? store.list()) ?? []
                } catch {
                    return nil
                }
            }.value
            guard !Task.isCancelled, let list = savedList else { return }
            editor.markSaved(normalized)
            self.presets = [.factoryDefault] + list
            if self.previewPresetOverride == editor.draft { self.previewPresetOverride = nil }
        }
    }

    /// Salva o rascunho (vindo do modelo de fábrica) como um modelo novo e passa a usá-lo.
    @discardableResult
    func saveDraftAsNewModel(_ editor: PresetEditorModel, name: String) -> Bool {
        liveSaveTask?.cancel()
        liveSaveTask = nil
        editor.draft.name = name
        guard editor.canSave, editor.save(into: presetStore) else { return false }
        reloadPresets(selecting: editor.draft.id, preserveContext: true)
        savePresetSelection()
        previewPresetOverride = nil
        return true
    }

    /// Largura de janela que cabe lateral + detalhe + painel do modelo.
    static let inspectorMinWindowWidth: CGFloat = 1080

    /// Abre ou fecha o painel do modelo. Abrindo numa janela estreita, a janela cresce ANTES (com animação)
    /// e só depois o painel aparece: sem isso as colunas se espremiam e voltavam num tranco.
    func setInspector(_ show: Bool) {
        guard show, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.isMainWindow }),
              window.frame.width < Self.inspectorMinWindowWidth else {
            inspectorShown = show
            return
        }
        var frame = window.frame
        let grow = Self.inspectorMinWindowWidth - frame.width
        frame.size.width += grow
        if let screen = window.screen?.visibleFrame, frame.maxX > screen.maxX {
            frame.origin.x = max(screen.minX, screen.maxX - frame.width)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor in self.inspectorShown = true }
        }
    }

    /// Nome do modelo em uso, avisando quando há alterações ainda não salvas no de fábrica.
    var workingModelLabel: String {
        let name = displayName(activePreset)
        return previewPresetOverride == nil ? name : name + " · " + String(localized: "model.unsaved")
    }

    /// Descarta o rascunho não salvo do modelo de fábrica.
    func discardDraft() {
        liveSaveTask?.cancel()
        liveSaveTask = nil
        previewPresetOverride = nil
        recomputeAllPreviews()
    }
}

// MARK: - Gerenciar modelos

extension AppModel {
    /// Abre a tela de gerenciar modelos.
    func requestManageModels() { showManageModels = true }

    func isFactory(_ id: String) -> Bool { id == Preset.factoryDefault.id }

    /// Exclui modelos (o de fábrica nunca). Se o modelo em uso sair, volta pro de fábrica.
    func deletePresets(_ ids: Set<String>) {
        if ids.contains(selectedPresetId) {
            liveSaveTask?.cancel()
            liveSaveTask = nil
            previewPresetOverride = nil
        }
        for id in ids where !isFactory(id) { _ = try? presetStore.delete(id: id) }
        if ids.contains(selectedPresetId) {
            reloadPresets(selecting: Preset.factoryDefault.id, preserveContext: true)
            savePresetSelection()
        } else {
            reloadPresets()
        }
    }

    func renamePreset(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !isFactory(id), !trimmed.isEmpty, var p = presets.first(where: { $0.id == id }) else { return }
        if id == selectedPresetId {
            liveSaveTask?.cancel()
            liveSaveTask = nil
        }
        p.name = trimmed
        do {
            try presetStore.save(p)
        } catch {
            modelError = error.localizedDescription
            return
        }
        reloadPresets()
    }

    /// Duplica com nome que não repete. Devolve o id da cópia.
    @discardableResult
    func duplicatePreset(_ id: String) -> String? {
        guard let p = presets.first(where: { $0.id == id }) else { return nil }
        let d = p.duplicated(newName: uniqueModelName(String(localized: "main.preset.copySuffix \(displayName(p))")))
        guard (try? presetStore.save(d)) != nil else { return nil }
        reloadPresets()
        return d.id
    }

    func exportPreset(_ id: String) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetStore.exportFilename(for: p)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = presetStore
        Task.detached { [weak self] in
            do {
                try store.export(p, to: url)
            } catch {
                await MainActor.run { [weak self] in
                    self?.modelError = error.localizedDescription
                }
            }
        }
    }

    func usePreset(_ id: String) {
        guard id != selectedPresetId else { return }
        selectedPresetId = id
    }

    /// "Projeto › Dia · Mês · Ano › Tipo de mídia": a receita de pastas de um modelo, em palavras.
    func folderRecipe(_ p: Preset) -> String {
        TemplateTokenizer.levels(from: p.folderStructure).map { Recipe.describe($0) }.joined(separator: " › ")
    }
}
