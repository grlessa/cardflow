import SwiftUI
import OffloadKit

/// Gerenciar modelos de pastas: todos numa lista, com a receita de cada um. Seleção múltipla, + e − no
/// rodapé (padrão do Mac), menu de contexto com Usar, Renomear, Duplicar, Exportar e Excluir.
struct ManageModelsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false
    @State private var renaming: Preset?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("models.manage.title").font(.title2.weight(.semibold))
                    Text("models.manage.subtitle").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            List(selection: $selection) {
                ForEach(model.presets, id: \.id) { p in
                    row(p)
                        .tag(p.id)
                        .contextMenu { contextMenu(p) }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: 300)
            .onDeleteCommand { if !deletable.isEmpty { confirmingDelete = true } }

            HStack(spacing: 6) {
                Button { model.requestNewModel(); dismiss() } label: { footerSymbol("plus") }
                    .help("menu.file.newModel")
                Button { confirmingDelete = true } label: { footerSymbol("minus") }
                    .help("models.delete.help")
                    .disabled(deletable.isEmpty)
                Divider().frame(height: 16)
                Button("main.preset.duplicate") { selection = Set(selection.compactMap { model.duplicatePreset($0) }) }
                    .disabled(selection.isEmpty)
                Button("menu.file.importModel") { model.requestImportModel() }
                Spacer()
                Button("models.use") { if let id = selection.first { model.usePreset(id) }; dismiss() }
                    .disabled(selection.count != 1)
                Button("models.done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .padding(14)
        }
        .frame(width: 620, height: 520)
        .spacedLabels()
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("main.preset.delete", role: .destructive) {
                model.deletePresets(deletable)
                selection.subtract(deletable)
            }
            Button("main.cancel", role: .cancel) {}
        } message: {
            Text("models.delete.message")
        }
        .alert("models.rename.title", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("preset.field.name", text: $newName)
            Button("models.rename.action") {
                if let r = renaming { model.renamePreset(r.id, to: newName) }
                renaming = nil
            }
            Button("main.cancel", role: .cancel) { renaming = nil }
        }
    }

    /// + e − com a mesma caixa: o símbolo "minus" é mais baixo e deixava o botão menor.
    private func footerSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .frame(width: 16, height: 16)
    }

    private var deletable: Set<String> { selection.filter { !model.isFactory($0) } }

    private var deleteTitle: Text {
        let names = model.presets.filter { deletable.contains($0.id) }.map(\.name)
        return names.count == 1 ? Text("main.preset.deleteConfirm \(names[0])")
                                : Text("models.delete.many \(names.count)")
    }

    private func row(_ p: Preset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.isFactory(p.id) ? "lock.fill" : "folder.badge.gearshape")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName(p)).lineLimit(1)
                    if p.id == model.selectedPresetId {
                        Text("models.inUse")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(.tint)
                    }
                }
                Text(model.folderRecipe(p)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func contextMenu(_ p: Preset) -> some View {
        Button("models.use") { model.usePreset(p.id) }
        Button("models.rename") { newName = p.name; renaming = p }.disabled(model.isFactory(p.id))
        Button("main.preset.duplicate") { if let id = model.duplicatePreset(p.id) { selection = [id] } }
        Button("menu.file.exportModel") { model.exportPreset(p.id) }
        Divider()
        Button("main.preset.delete", role: .destructive) {
            selection = [p.id]
            confirmingDelete = true
        }
        .disabled(model.isFactory(p.id))
    }
}
