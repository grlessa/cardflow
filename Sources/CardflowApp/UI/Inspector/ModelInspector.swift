import SwiftUI
import OffloadKit

/// Painel do modelo de pastas, à direita. Mostra cada pasta como ela vai ficar de verdade (com o cartão
/// selecionado) e do que ela é feita; editar abre um balão com as peças. Muda a prévia na hora e o modelo
/// do usuário é salvo sozinho. O de fábrica não muda: as alterações viram um modelo novo ao salvar.
struct ModelInspector: View {
    @Environment(AppModel.self) private var model
    @State private var editor: PresetEditorModel?
    @State private var newName = ""
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                ProgressView()
            }
        }
        .onAppear { load() }
        .onChange(of: model.selectedPresetId) { load() }
        .onChange(of: editor?.draft) { if let editor { model.applyLiveDraft(editor) } }
    }

    private func load() {
        editor = model.makeLiveEditor()
        newName = model.uniqueModelName(String(localized: "model.new.defaultName"))
    }

    @ViewBuilder private func content(_ editor: PresetEditorModel) -> some View {
        @Bindable var editor = editor
        let ex = examples(editor)
        DetailScroll {
            identity(editor)
            ModelPreview(original: ex.original, folders: ex.folders, file: ex.file, renamed: editor.draft.rename.enabled)

            DetailSection("inspector.folders") {
                // um bloco só: o trilho que liga as pastas atravessa as linhas sem divisória no meio
                VStack(spacing: 0) {
                    ForEach(editor.folderLevels.indices, id: \.self) { i in
                        FolderLevelRow(editor: editor, index: i, example: ex.folders[safe: i] ?? "",
                                       render: { renderLevel(editor, $0) })
                    }
                }
                Button { editor.addFolderLevel() } label: {
                    Label("inspector.folders.add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("inspector.fileName")
                VStack(spacing: 6) {
                    OptionRow(symbol: "sdcard", title: "inspector.name.keep", example: ex.original,
                              on: !editor.draft.rename.enabled) { editor.draft.rename.enabled = false }
                    OptionRow(symbol: "textformat.abc", title: "inspector.name.rename", example: ex.renamed,
                              on: editor.draft.rename.enabled) { editor.draft.rename.enabled = true }
                }
                if editor.draft.rename.enabled {
                    FileNameRow(editor: editor, example: ex.file, render: { renderName(editor, $0) })
                        .padding(12)
                        .background(.background.secondary, in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("inspector.what")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    MediaOption(symbol: "hand.tap", title: "inspector.media.ask", on: editor.draft.media.mode == .open) {
                        editor.draft.media.mode = .open
                    }
                    ForEach([Preset.Media.Kind.photo, .video, .audio, .both], id: \.self) { k in
                        MediaOption(symbol: MediaOption.symbol(k), title: MediaOption.title(k),
                                    on: editor.draft.media.mode == .locked && editor.draft.media.lockedTo == k) {
                            editor.draft.media.mode = .locked
                            editor.draft.media.lockedTo = k
                        }
                    }
                }
                Text(editor.draft.media.mode == .open ? String(localized: "inspector.media.ask.detail")
                                                      : String(localized: "inspector.media.locked.detail \(MediaChoiceText.name(editor.draft.media.lockedTo))"))
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                ToggleRow(symbol: "doc.on.doc", title: "inspector.sidecars", detail: "inspector.sidecars.detail",
                          isOn: Binding(get: { editor.draft.copySidecars == .aside },
                                        set: { editor.draft.copySidecars = $0 ? .aside : .skip }))
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("inspector.project")
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").font(.title3).foregroundStyle(.tint)
                    DeferredTextField("inspector.defaultProject", text: $editor.draft.evento)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
                .help("inspector.defaultProject.help")
                Text("inspector.defaultProject.short").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("inspector.fields")
                VStack(alignment: .leading, spacing: 10) {
                    if editor.draft.sessionFields.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "character.textbox").font(.title2).foregroundStyle(.tint)
                            Text("inspector.fields.empty").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(editor.draft.sessionFields.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Image(systemName: "character.textbox").foregroundStyle(.tint)
                            DeferredTextField("preset.sessionField.labelPlaceholder", text: $editor.draft.sessionFields[index].label)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { editor.removeSessionField(at: index) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("inspector.fields.remove")
                        }
                    }
                    Button { editor.addSessionField() } label: { Label("preset.sessionField.add", systemImage: "plus") }
                        .help("preset.customFields.hint")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
            }

            if let problem = editor.saveDisabledReason ?? editor.previewError {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                Button { model.duplicateActivePreset() } label: { Label("main.preset.duplicate", systemImage: "plus.square.on.square") }
                Button { model.requestManageModels() } label: { Label("models.manage.menu", systemImage: "list.bullet") }
                Spacer()
                if editor.canDelete {
                    Button("preset.button.delete", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog(Text("main.preset.deleteConfirm \(model.displayName(model.activePreset))"),
                                        isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("main.preset.delete", role: .destructive) { model.deleteActivePreset() }
                        Button("main.cancel", role: .cancel) {}
                    }
                }
            }
        }
        .disabled(model.cards.contains { $0.isBusy })
    }

    // MARK: Identidade do modelo

    @ViewBuilder private func identity(_ editor: PresetEditorModel) -> some View {
        @Bindable var editor = editor
        if editor.isNew {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(.tint)
                Text(model.displayName(model.activePreset)).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Label("inspector.factory.tag", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .labelStyle(SpacedLabelStyle())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: .capsule)
                    .help("inspector.factory.notice")
            }
            .padding(.horizontal, 4)
            if editor.hasUnsavedChanges {
                Callout(symbol: "square.and.pencil", tint: .accentColor,
                        title: String(localized: "inspector.factory.changed")) {
                    TextField("inspector.factory.name", text: $newName).textFieldStyle(.roundedBorder).padding(.top, 4)
                    // lado a lado quando cabem; no painel estreito, um embaixo do outro (sem cortar o texto)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            discardButton
                            Spacer()
                            saveButton(editor)
                        }
                        VStack(alignment: .trailing, spacing: 6) {
                            saveButton(editor)
                            discardButton
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }
            }
        } else {
            DetailSection("inspector.model") {
                DeferredTextField("preset.field.name", text: $editor.draft.name).textFieldStyle(.roundedBorder)
                if let warning = editor.duplicateNameWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
    }

    private var discardButton: some View {
        Button("inspector.factory.discard") { model.discardDraft(); load() }.fixedSize()
    }

    private func saveButton(_ editor: PresetEditorModel) -> some View {
        Button("inspector.factory.save") {
            if model.saveDraftAsNewModel(editor, name: newName.trimmingCharacters(in: .whitespaces)) { load() }
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: Exemplo real

    /// Nome que um nível de pasta teria com estas peças (mesmo arquivo e contexto da prévia).
    private func renderLevel(_ editor: PresetEditorModel, _ segs: [TemplateSegment]) -> String {
        guard !segs.isEmpty else { return "" }
        var preset = editor.draft
        preset.folderStructure = TemplateTokenizer.serialize(segs)
        preset.rename.enabled = false
        let (file, ctx) = exampleInputs(&preset)
        guard let rel = try? NameBuilder(preset: preset, locale: AppLocale.effective).relativeDestination(for: file, context: ctx) else { return "" }
        let parts = rel.split(separator: "/").map(String.init)
        return parts.count > 1 ? parts[0] : ""
    }

    /// Nome de arquivo que estas peças dariam (com renomear ligado).
    private func renderName(_ editor: PresetEditorModel, _ segs: [TemplateSegment]) -> String {
        guard !segs.isEmpty else { return "" }
        var preset = editor.draft
        preset.rename.enabled = true
        preset.rename.template = TemplateTokenizer.serialize(segs)
        let (file, ctx) = exampleInputs(&preset)
        guard let rel = try? NameBuilder(preset: preset, locale: AppLocale.effective).relativeDestination(for: file, context: ctx) else { return "" }
        return (rel as NSString).lastPathComponent
    }

    /// Arquivo e contexto de exemplo: o 1º arquivo do tipo escolhido no cartão selecionado (ou um de
    /// exemplo), com o projeto da barra.
    private func exampleInputs(_ preset: inout Preset) -> (MediaFile, NamingContext) {
        let project = model.projectName.trimmingCharacters(in: .whitespaces)
        preset.evento = NameBuilder.sanitizePathComponent(project.isEmpty ? preset.evento : project)
        let card = model.selectedCard
        let wanted: Set<FileType> = {
            switch card.map({ model.effectiveMedia($0) }) ?? .both {
            case .photo: [.photo]
            case .video: [.video]
            case .audio: [.audio]
            case .both: [.photo, .video, .audio]
            }
        }()
        let file = card?.scanned?.first { wanted.contains($0.type) && !$0.preserve } ?? .previewSample
        var session = model.sessionValues
        session["camera"] = card?.camera ?? "CAM A"
        let ctx = NamingContext(camera: card?.camera ?? "CAM A", counter: 1, cardName: card?.volume.name ?? "A001",
                                sessionValues: session, lote: card?.preview?.lote?.numero ?? 1)
        return (file, ctx)
    }

    /// Nomes de exemplo de cada pasta e do arquivo, com o mesmo motor da cópia: o 1º arquivo do cartão
    /// selecionado, ou um arquivo de exemplo quando não há cartão.
    private func examples(_ editor: PresetEditorModel) -> (folders: [String], file: String, original: String, renamed: String) {
        var preset = editor.draft
        let (file, ctx) = exampleInputs(&preset)
        guard let rel = try? NameBuilder(preset: preset, locale: AppLocale.effective).relativeDestination(for: file, context: ctx) else {
            return ([], "", "", "")
        }
        var parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let name = parts.popLast() ?? ""
        // o nome que sairia renomeando, pra mostrar a opção antes de escolher
        var renamedPreset = preset
        renamedPreset.rename.enabled = true
        let renamedRel = (try? NameBuilder(preset: renamedPreset, locale: AppLocale.effective).relativeDestination(for: file, context: ctx)) ?? rel
        return (parts, name, (file.relPath as NSString).lastPathComponent, (renamedRel as NSString).lastPathComponent)
    }
}

// MARK: - Escolhas

/// Opção em linha: ícone, título e o exemplo real em fonte de código; a escolhida acende.
private struct OptionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let example: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(on ? Color.accentColor : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(verbatim: example).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(10)
            .background(on ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(hovering ? 0.10 : 0.05), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Bloco pequeno de mídia: ícone em cima, nome embaixo.
private struct MediaOption: View {
    let symbol: String
    let title: LocalizedStringKey
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    static func symbol(_ k: Preset.Media.Kind) -> String {
        switch k { case .photo: "photo"; case .video: "video"; case .audio: "waveform"; case .both: "square.stack.3d.up" }
    }
    static func title(_ k: Preset.Media.Kind) -> LocalizedStringKey {
        switch k { case .photo: "main.media.photo"; case .video: "main.media.video"; case .audio: "main.media.audio"; case .both: "main.media.all" }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3).frame(height: 22)
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.accentColor : .primary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(hovering ? 0.10 : 0.05), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Liga e desliga com ícone, título e uma linha do que faz.
private struct ToggleRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(isOn ? Color.accentColor : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle(isOn: $isOn) { Text(title) }.toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

// MARK: - Prévia

/// O exemplo inteiro de uma vez: o arquivo do cartão, a seta e onde ele cai, com o nome final.
private struct ModelPreview: View {
    let original: String
    let folders: [String]
    let file: String
    let renamed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sdcard").foregroundStyle(.secondary)
                Text(verbatim: original).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Image(systemName: "arrow.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.leading, 4)
            FlowLayout(spacing: 4, lineSpacing: 5) {
                ForEach(Array(folders.enumerated()), id: \.offset) { i, f in
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").font(.caption).foregroundStyle(.tint)
                        Text(f).font(.callout).lineLimit(1)
                    }
                    if i < folders.count - 1 {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "doc.fill").foregroundStyle(renamed ? Color.accentColor : .secondary)
                Text(verbatim: file).font(.system(.callout, design: .monospaced).weight(renamed ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("inspector.preview.a11y"))
    }
}

// MARK: - Linhas

/// Uma pasta: o nome que ela vai ter e do que é feita. Clicar edita no balão.
private struct FolderLevelRow: View {
    @Bindable var editor: PresetEditorModel
    let index: Int
    let example: String
    let render: ([TemplateSegment]) -> String
    @State private var editing = false

    private var isLast: Bool { index >= editor.folderLevels.count - 1 }

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 10) {
                // trilho: cada pasta fica dentro da de cima, ligadas por uma linha, como um caminho. Sem
                // número nem recuo (recuo crescente vazava do painel com muitas pastas).
                VStack(spacing: 3) {
                    Rectangle().fill(.tertiary).frame(width: 1.5).opacity(index == 0 ? 0 : 1)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                    Rectangle().fill(.tertiary).frame(width: 1.5).opacity(isLast ? 0 : 1)
                }
                .frame(width: 22)
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 1) {
                    Text(example.isEmpty ? String(localized: "inspector.folder.empty") : example)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(example.isEmpty ? .secondary : .primary)
                    Text(Recipe.describe(editor.folderLevels[safe: index] ?? []))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.vertical, 7)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .leading) {
            FolderLevelEditor(editor: editor, index: index, example: example, render: render) {
                editing = false
                editor.removeFolderLevel(index)
            }
        }
    }

}

/// O nome do arquivo: exemplo real e receita; clicar edita no balão.
private struct FileNameRow: View {
    @Bindable var editor: PresetEditorModel
    let example: String
    let render: ([TemplateSegment]) -> String
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(example).lineLimit(1).truncationMode(.middle)
                    Text(Recipe.describe(editor.nameSegments)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .leading) {
            FileNameEditor(editor: editor, example: example, render: render)
        }
    }
}

/// "Dia · Mês curto · Ano": do que uma pasta (ou o nome) é feita, em palavras.
enum Recipe {
    static func describe(_ segments: [TemplateSegment]) -> String {
        let parts: [String] = segments.compactMap { seg in
            switch seg {
            case .token(let name, _):
                guard let info = TokenCatalog.info(for: name) else { return name }
                // "Dia (28)" vira "Dia": o exemplo real já aparece na linha de cima.
                let label = String(localized: String.LocalizationValue(info.label))
                return label.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            case .literal(let text):
                let t = text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || ["_", "-", ".", "·"].contains(t) ? nil : "“\(t)”"
            }
        }
        return parts.isEmpty ? String(localized: "inspector.folder.empty") : parts.joined(separator: " · ")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
