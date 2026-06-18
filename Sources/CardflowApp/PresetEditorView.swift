import SwiftUI
import OffloadKit

/// Editor de preset em wizard de passos clicáveis (Plano 7). A nomeação é montada por peças.
struct PresetEditorView: View {
    @Bindable var model: PresetEditorModel
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
            stepBar
            Divider()
            ScrollView { stepContent.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 600, height: 620)
        .alert("preset.alert.saveTitle", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("preset.alert.ok", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isNew ? "preset.title.new" : "preset.title.edit").font(.title2.weight(.semibold))
                Text("preset.subtitle").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
    }

    private var stepBar: some View {
        Picker("", selection: $model.step) {
            ForEach(PresetEditorModel.Step.allCases) { s in Text(s.titulo).tag(s) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .basico: basico
        case .nomeacao: nomeacao
        }
    }

    // 1. Básico (identidade + mídia)
    private var basico: some View {
        VStack(alignment: .leading, spacing: 16) {
            secao("preset.section.identity") {
                campo("preset.field.name") { TextField("preset.placeholder.name", text: $model.draft.name) }
                campo("preset.field.parentFolder") { TextField("preset.placeholder.parentFolder", text: $model.draft.evento) }
                Text("preset.field.parentFolder.hint")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secao("preset.section.whatToCopy") {
                Picker("", selection: $model.draft.media.mode) {
                    Text("preset.media.askEveryTime").tag(Preset.Media.Mode.open)
                    Text("preset.media.lockedToPreset").tag(Preset.Media.Mode.locked)
                }.labelsHidden().pickerStyle(.radioGroup)
                if model.draft.media.mode == .locked {
                    campo("preset.field.copy") {
                        Picker("", selection: $model.draft.media.lockedTo) {
                            Text("preset.media.photos").tag(Preset.Media.Kind.photo)
                            Text("preset.media.videos").tag(Preset.Media.Kind.video)
                            Text("preset.media.audio").tag(Preset.Media.Kind.audio)
                            Text("preset.media.all").tag(Preset.Media.Kind.both)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                }
            }
            secao("preset.section.options") {
                Toggle("preset.options.copySidecars", isOn: Binding(
                    get: { model.draft.copySidecars == .aside },
                    set: { model.draft.copySidecars = $0 ? .aside : .skip }
                ))
            }
        }
    }

    // 2. Nomeação (o coração) — pastas, nome do arquivo e campos personalizados (usados como tokens).
    private var nomeacao: some View {
        VStack(alignment: .leading, spacing: 16) {
            secao("preset.section.folders") {
                Text("preset.folders.hint")
                    .font(.caption).foregroundStyle(.secondary)
                FolderLevelsBuilder(model: model, sessionFields: model.draft.sessionFields)
            }
            secao("preset.section.fileName") {
                Toggle("preset.rename.toggle", isOn: $model.draft.rename.enabled)
                if model.draft.rename.enabled {
                    Text("preset.rename.joinersHint")
                        .font(.caption).foregroundStyle(.secondary)
                    PillBuilderView(model: model, lane: .name, sessionFields: model.draft.sessionFields)
                } else {
                    Text("preset.rename.keepOriginal").font(.callout).foregroundStyle(.secondary)
                }
            }
            secao("preset.section.customFields") {
                Text("preset.customFields.hint").font(.caption).foregroundStyle(.secondary)
                sessionFieldsEditor
            }
        }
    }

    private var sessionFieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.draft.sessionFields.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField("preset.sessionField.labelPlaceholder", text: $model.draft.sessionFields[index].label)
                    TextField("preset.sessionField.keyPlaceholder", text: $model.draft.sessionFields[index].key).font(.body.monospaced()).foregroundStyle(.secondary)
                    Button(role: .destructive) { model.removeSessionField(at: index) } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.borderless)
                }
            }
            Button { model.addSessionField() } label: { Label("preset.sessionField.add", systemImage: "plus.circle") }
        }
    }

    private func campo<C: View>(_ titulo: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    /// Seção com moldura sutil + título — dá hierarquia visual clara entre os blocos.
    private func secao<C: View>(_ titulo: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo).textCase(.uppercase).font(.caption2.weight(.bold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("preset.preview.title")
                .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            if let err = model.previewError {
                Label(err, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            } else if let parts = model.previewParts {
                FlowRow(spacing: 6) {
                    ForEach(Array(parts.folders.enumerated()), id: \.offset) { _, folder in
                        previewChip(folder, icon: "folder.fill", isFile: false)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    previewChip(parts.file, icon: "doc.fill", isFile: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func previewChip(_ text: String, icon: String, isFile: Bool) -> some View {
        let color = isFile ? Color.accentColor : Color.secondary
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(isFile ? Color.accentColor : .primary)
        }
        .padding(.horizontal, 9).frame(height: 26)
        .background(Capsule().fill(color.opacity(0.13)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canDelete {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("preset.button.delete", systemImage: "trash") }
                    .confirmationDialog("preset.delete.confirmTitle", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("preset.delete.confirmAction", role: .destructive, action: onDelete)
                        Button("preset.button.cancel", role: .cancel) {}
                    }
            }
            if let reason = model.saveDisabledReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let aviso = model.duplicateNameWarning {
                Label(aviso, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Button("preset.button.cancel", role: .cancel) {
                // #23: não descarta uma edição trabalhosa sem confirmar (igual à exclusão).
                if model.hasUnsavedChanges { confirmingDiscard = true } else { onCancel() }
            }
            .keyboardShortcut(.cancelAction)
            .confirmationDialog("preset.discard.confirmTitle", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("preset.discard.confirmAction", role: .destructive, action: onCancel)
                Button("preset.discard.keepEditing", role: .cancel) {}
            }
            if model.step != .basico {
                Button("preset.button.back") { model.step = PresetEditorModel.Step(rawValue: model.step.rawValue - 1)! }
            }
            if model.step != .nomeacao {
                Button("preset.button.next") { model.step = PresetEditorModel.Step(rawValue: model.step.rawValue + 1)! }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("preset.button.save", action: onSave).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
