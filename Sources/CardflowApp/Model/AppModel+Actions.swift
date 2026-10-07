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

    func addDestinationFolder(_ url: URL) {
        let isVolumeRoot = watcher.volumes.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
        if !isVolumeRoot && !customFolders.contains(url) && !internalShortcuts().contains(where: { $0.url == url }) {
            customFolders.append(url)
        }
        setUserDestination(url)
        selection = .destination(url)
    }

    /// Tira uma pasta da lista de destinos lembrados (não apaga nada do disco).
    func forgetDestinationFolder(_ url: URL) {
        customFolders.removeAll { $0 == url }
        if destinationURL == url { destinationURL = nil }
        if backupURL == url { backupURL = nil }
        reconcileVolumes()
        saveDiskSelection()
    }

    func setBackup(_ url: URL?) {
        backupURL = url
        if url != nil, url == destinationURL { destinationURL = nil }
        reconcileVolumes()
        saveDiskSelection()
    }

    enum DestinationRole { case principal, backup, none }
    func role(of url: URL) -> DestinationRole {
        if url == destinationURL { return .principal }
        if url == backupURL { return .backup }
        return .none
    }
    func setRole(_ role: DestinationRole, for url: URL) {
        switch role {
        case .principal:
            if backupURL == url { backupURL = nil }
            setUserDestination(url)
        case .backup: setBackup(url)
        case .none:
            if destinationURL == url { destinationURL = nil; preferredDestUUID = nil }
            if backupURL == url { backupURL = nil }
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
        do { try importPreset(from: url) } catch { modelError = String(localized: "main.importError") }
    }

    func requestExportModel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetStore.exportFilename(for: activePreset)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportActivePreset(to: url)
    }

    /// Novo modelo a partir do de fábrica, já salvo e selecionado; o painel do modelo abre pra editar.
    func requestNewModel() {
        var p = Preset.factoryDefault
        p.id = UUID().uuidString
        p.name = uniqueModelName(String(localized: "model.new.defaultName"))
        try? presetStore.save(p)
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
    /// Editor do modelo ativo pro painel lateral. O de fábrica vira um rascunho de modelo novo.
    func makeLiveEditor() -> PresetEditorModel {
        let ed = PresetEditorModel.editing(activePreset)
        ed.otherNames = Set(presets.filter { $0.id != ed.draft.id }.map(\.name))
        return ed
    }

    /// Cada mudança no painel: a prévia mostra na hora; um modelo do usuário é salvo sozinho depois de
    /// uma pausa curta. O de fábrica só vira modelo quando o usuário salva com um nome.
    func applyLiveDraft(_ editor: PresetEditorModel) {
        guard editor.hasUnsavedChanges else {
            if previewPresetOverride != nil { previewPresetOverride = nil; recomputeAllPreviews() }
            return
        }
        previewPresetOverride = editor.draft
        recomputeAllPreviews()
        guard !editor.isNew else { return }
        liveSaveTask?.cancel()
        liveSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, editor.canSave, editor.save(into: self.presetStore) else { return }
            self.presets = [.factoryDefault] + ((try? self.presetStore.list()) ?? [])
            if self.previewPresetOverride == editor.draft { self.previewPresetOverride = nil }
        }
    }

    /// Salva o rascunho (vindo do modelo de fábrica) como um modelo novo e passa a usá-lo.
    @discardableResult
    func saveDraftAsNewModel(_ editor: PresetEditorModel, name: String) -> Bool {
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
        for id in ids where !isFactory(id) { try? presetStore.delete(id: id) }
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
        p.name = trimmed
        try? presetStore.save(p)
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
        try? presetStore.export(p, to: url)
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
