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
        .alert("Não foi possível salvar", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isNew ? "Novo preset" : "Editar preset").font(.title2.weight(.semibold))
                Text("Como os arquivos vão ser organizados e renomeados").font(.caption).foregroundStyle(.secondary)
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
        case .avancado: avancado
        }
    }

    // 1. Básico (identidade + mídia)
    private var basico: some View {
        VStack(alignment: .leading, spacing: 16) {
            secao("Identidade") {
                campo("Nome do preset") { TextField("Ex.: Culto de domingo", text: $model.draft.name) }
                campo("Pasta-mãe padrão (evento)") { TextField("Ex.: Culto", text: $model.draft.evento) }
            }
            secao("O que copiar") {
                Picker("", selection: $model.draft.media.mode) {
                    Text("Quem copia escolhe na hora").tag(Preset.Media.Mode.open)
                    Text("Travado neste preset").tag(Preset.Media.Mode.locked)
                }.labelsHidden().pickerStyle(.radioGroup)
                if model.draft.media.mode == .locked {
                    campo("Copiar") {
                        Picker("", selection: $model.draft.media.lockedTo) {
                            Text("Fotos").tag(Preset.Media.Kind.photo)
                            Text("Vídeos").tag(Preset.Media.Kind.video)
                            Text("Áudio").tag(Preset.Media.Kind.audio)
                            Text("Tudo").tag(Preset.Media.Kind.both)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    // 2. Nomeação (o coração)
    private var nomeacao: some View {
        VStack(alignment: .leading, spacing: 16) {
            secao("Pastas") {
                Text("Cada linha é uma pasta, e a de baixo fica dentro da de cima. Use “+ Texto…” pra digitar um nome fixo (ex.: Culto).")
                    .font(.caption).foregroundStyle(.secondary)
                FolderLevelsBuilder(model: model, sessionFields: model.draft.sessionFields)
            }
            secao("Nome do arquivo") {
                Toggle("Renomear os arquivos ao copiar", isOn: $model.draft.rename.enabled)
                if model.draft.rename.enabled {
                    Text("Os juntadores cinza (· - _) entre as peças definem como elas se unem. Toque num pra trocar.")
                        .font(.caption).foregroundStyle(.secondary)
                    PillBuilderView(model: model, lane: .name, sessionFields: model.draft.sessionFields)
                } else {
                    Text("Os arquivos mantêm o nome original da câmera.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // 3. Avançado
    private var avancado: some View {
        VStack(alignment: .leading, spacing: 16) {
            secao("Campos personalizados") {
                Text("Viram peças que você pode usar na nomeação (ex.: Fotógrafo).").font(.caption).foregroundStyle(.secondary)
                sessionFieldsEditor
            }
            secao("Opções") {
                Toggle("Copiar arquivos-irmãos (sidecars) junto", isOn: Binding(
                    get: { model.draft.copySidecars == .aside },
                    set: { model.draft.copySidecars = $0 ? .aside : .skip }
                ))
                campo("Idioma das datas") {
                    Picker("", selection: $model.draft.locale) {
                        Text("Português (BR)").tag("pt_BR"); Text("Inglês (US)").tag("en_US"); Text("Espanhol (ES)").tag("es_ES")
                    }.labelsHidden()
                }
            }
            secao("Extensões reconhecidas") {
                Text("Quais tipos de arquivo o Cardflow identifica (padrão do sistema).").font(.caption).foregroundStyle(.secondary)
                extLinha("Fotos", model.draft.photoExtensions)
                extLinha("Vídeos", model.draft.videoExtensions)
                extLinha("Áudio", model.draft.audioExtensions)
                extLinha("Sidecars (XMP, THM…)", model.draft.sidecarExtensions)
            }
        }
    }

    private func extLinha(_ titulo: String, _ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.caption).foregroundStyle(.secondary)
            TagListView(tags: tags)
        }
    }

    private var sessionFieldsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.draft.sessionFields.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField("Rótulo", text: $model.draft.sessionFields[index].label)
                    TextField("chave", text: $model.draft.sessionFields[index].key).font(.body.monospaced()).foregroundStyle(.secondary)
                    Button(role: .destructive) { model.removeSessionField(at: index) } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.borderless)
                }
            }
            Button { model.addSessionField() } label: { Label("Adicionar campo", systemImage: "plus.circle") }
        }
    }

    private func campo<C: View>(_ titulo: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    /// Seção com moldura sutil + título — dá hierarquia visual clara entre os blocos.
    private func secao<C: View>(_ titulo: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titulo.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PRÉVIA — onde um arquivo vai parar")
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
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Excluir", systemImage: "trash") }
                    .confirmationDialog("Excluir este preset?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Excluir preset", role: .destructive, action: onDelete)
                        Button("Cancelar", role: .cancel) {}
                    }
            }
            if let reason = model.saveDisabledReason {
                Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let aviso = model.duplicateNameWarning {
                Label(aviso, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Button("Cancelar", role: .cancel) {
                // #23: não descarta uma edição trabalhosa sem confirmar (igual à exclusão).
                if model.hasUnsavedChanges { confirmingDiscard = true } else { onCancel() }
            }
            .keyboardShortcut(.cancelAction)
            .confirmationDialog("Descartar as alterações deste preset?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Descartar", role: .destructive, action: onCancel)
                Button("Continuar editando", role: .cancel) {}
            }
            if model.step != .basico {
                Button("Voltar") { model.step = PresetEditorModel.Step(rawValue: model.step.rawValue - 1)! }
            }
            if model.step != .avancado {
                Button("Próximo") { model.step = PresetEditorModel.Step(rawValue: model.step.rawValue + 1)! }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Salvar", action: onSave).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
