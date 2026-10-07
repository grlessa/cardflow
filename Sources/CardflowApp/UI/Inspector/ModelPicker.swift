import SwiftUI
import OffloadKit

/// Seletor do modelo de pastas na barra de ferramentas: ícone, nome do modelo em uso e setinha, no mesmo
/// formato do campo de projeto. É um botão com balão (e não um `Menu`) porque, no macOS 26, a barra
/// transforma todo menu num botão redondo só com ícone e o nome some.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                Text(model.displayName(model.activePreset)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("toolbar.model.choose.help")
        .disabled(model.cards.contains { $0.isBusy })
        .accessibilityLabel(Text("toolbar.model.label \(model.displayName(model.activePreset))"))
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("toolbar.model.choose").font(.headline).padding(.horizontal, 10).padding(.bottom, 4)
            ScrollView {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(model.presets, id: \.id) { p in
                Button {
                    model.selectedPresetId = p.id
                    open = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").opacity(p.id == model.selectedPresetId ? 1 : 0).foregroundStyle(.tint)
                        Text(model.displayName(p)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                }
              }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 6)
            Group {
                Button { open = false; model.requestNewModel() } label: { Label("menu.file.newModel", systemImage: "plus") }
                Button { open = false; model.requestImportModel() } label: { Label("menu.file.importModel", systemImage: "square.and.arrow.down") }
                Button { open = false; model.requestExportModel() } label: { Label("menu.file.exportModel", systemImage: "square.and.arrow.up") }
                Button { open = false; model.requestManageModels() } label: { Label("models.manage.menu", systemImage: "list.bullet") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
        .spacedLabels()
    }
}
