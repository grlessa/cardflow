import SwiftUI
import OffloadKit

/// Escolhe o que mostrar no detalhe conforme a seleção da barra lateral.
struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .destination(let url)?:
            if let v = model.volume(url) { DestinationDetailView(volume: v) } else { EmptyStateView() }
        case .recent(let id)?:
            if let item = model.history.item(id) { RecentDetailView(item: item) } else { EmptyStateView() }
        default:
            if let card = model.selectedCard { CardDetailView(card: card).id(card.id) } else { EmptyStateView() }
        }
    }
}

/// Detalhe de um cartão, desenhado como a cópia que vai acontecer: a rota (cartão → destinos, com o
/// caminho final), o que copiar em blocos e a árvore de pastas. A ação fica sempre na barra de baixo.
struct CardDetailView: View {
    @Environment(AppModel.self) private var model
    let card: CardSession
    @State private var showingIgnored = false

    var body: some View {
        DetailScroll {
            CopyRouteView(card: card)
            alerts
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("detail.section.what")
                MediaTiles(card: card)
                facts
            }
            if card.isMultiCamera {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("camera.section")
                    CameraEntriesView(card: card)
                }
            }
            DetailSection("detail.section.tree") {
                Text("detail.tree.model \(model.workingModelLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } content: {
                OrganizationTreeView(card: card)
            }
            Color.clear.frame(height: 70)   // espaço pra barra de ação não cobrir o fim
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ActionBar(card: card) }
        .sheet(isPresented: $showingIgnored) { IgnoredFilesView(paths: card.preview?.junkPaths ?? []) }
        .navigationTitle(card.volume.name)
    }

    // MARK: Avisos

    /// O que pede atenção antes de copiar, em destaque e na cor do estado.
    @ViewBuilder private var alerts: some View {
        if let title = card.resumeCardTitle, let detail = card.resumeCardDetail {
            Callout(symbol: card.isComplementalCopy ? "plus.circle.fill" : "arrow.clockwise.circle.fill",
                    tint: .accentColor, title: title, detail: detail)
        }
        if let inc = card.preview?.lote?.anteriorIncompleto {
            Callout(symbol: "exclamationmark.octagon.fill", tint: .red,
                    title: String(localized: "main.lote.incomplete \(String(format: "%02d", inc))")) {
                Toggle("main.lote.acknowledgeNew", isOn: Binding(get: { card.acknowledgedIncompleteLote == inc },
                                                                  set: { card.acknowledgedIncompleteLote = $0 ? inc : nil }))
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
            }
        }
        if model.backupURL != nil && model.backupNotConfirmed {
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange, title: String(localized: "main.dest.backupNotConfirmed"))
        }
        if model.internalPermissionDenied {
            Callout(symbol: "lock.fill", tint: .orange, title: String(localized: "main.dest.permissionDenied"))
        }
        if let ex = model.autoFormatWarning(card) {
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                    title: String(localized: "format.auto.warning \(FormatConfirmSheet.summary(ex))"))
        }
    }

    // MARK: Detalhes do conteúdo

    /// Datas, lote, itens ignorados e não reconhecidos, em etiquetas embaixo dos blocos.
    @ViewBuilder private var facts: some View {
        if let pv = card.preview {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                CaptureDateFilterButton(card: card)
                if let lote = pv.lote {
                    FactChip(symbol: "number", text: String(localized: "main.lote.label \(String(format: "%02d", lote.numero)) \(String(localized: lote.isNovo ? "main.lote.new" : "main.lote.continues"))"))
                }
                if pv.junk > 0 {
                    Button { showingIgnored = true } label: {
                        FactChip(symbol: "eye.slash", text: String(localized: "detail.ignored") + " · " + String(localized: "count.items \(pv.junk)"))
                    }
                    .buttonStyle(.plain)
                    .help("detail.ignored.show")
                }
                if !pv.unrecognized.isEmpty {
                    FactChip(symbol: "questionmark.folder", text: String(localized: "detail.unrecognized") + " · \(pv.unrecognized.count)")
                        .help("detail.unrecognized.help")
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Título de grupo solto (sem caixa em volta), no mesmo estilo dos títulos de seção.
struct SectionTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View { Text(key).font(.headline).padding(.horizontal, 4) }
}

enum MediaChoiceText {
    static func name(_ k: Preset.Media.Kind) -> String {
        switch k {
        case .photo: String(localized: "main.media.photo")
        case .video: String(localized: "main.media.video")
        case .audio: String(localized: "main.media.audio")
        case .both: String(localized: "main.media.all")
        }
    }
}

extension CardSession {
    /// "Cartão SD · 128 GB · leitor do Mac"
    var kindLine: String {
        let isImage = volume.traits?.protocolName == "Virtual Interface"
        var parts = [isImage ? String(localized: "detail.kind.diskImage")
                             : String(localized: MediaIllustration.name(for: volume.mediaKind))]
        if let total = volume.totalBytes { parts.append(Format.bytes(total)) }
        switch volume.traits?.protocolName {
        case "Secure Digital"?: parts.append(String(localized: "detail.reader.builtIn"))
        case "USB"?: parts.append(String(localized: "detail.reader.usb"))
        case "Thunderbolt"?, "PCI-Express"?: parts.append(String(localized: "detail.reader.thunderbolt"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Vai ficar assim

struct OrganizationTreeView: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        let root = model.volume(model.destinationURL)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if let root { MediaIllustration(kind: root.mediaKind, size: 18, volumeURL: root.url) }
                Text(root?.name ?? String(localized: "main.diskName.fallback")).foregroundStyle(.secondary)
            }
            if card.tree.isEmpty {
                Text(card.preview == nil ? "main.card.calculating" : "detail.tree.empty")
                    .foregroundStyle(.secondary)
                    .padding(.leading, TreeRow.indent)
            } else {
                ForEach(card.tree) { TreeRow(node: $0, depth: 1) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Uma pasta da árvore, com recuo fixo por nível; abre e fecha pelo triângulo. Os nomes de exemplo ficam
/// alinhados embaixo da pasta onde vão cair.
private struct TreeRow: View {
    static let indent: CGFloat = 20
    /// Recuo por nível com teto: modelo com muitas pastas não empurra a árvore pra fora da tela.
    static func leading(_ depth: Int) -> CGFloat { CGFloat(min(depth - 1, 5)) * indent }
    let node: TreeNode
    let depth: Int
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if node.children != nil {
                    Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(expanded ? "detail.tree.collapse" : "detail.tree.expand"))
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "\(String(localized: "count.files \(node.count)")) · \(Format.bytes(node.bytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.leading, Self.leading(depth))
            if expanded {
                ForEach(node.children ?? []) { TreeRow(node: $0, depth: depth + 1) }
                if !node.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(node.samples, id: \.self) { name in
                            HStack(spacing: 6) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                Text(verbatim: name).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if node.count > node.samples.count {
                            Text("detail.tree.more \(node.count - node.samples.count)")
                                .font(.subheadline).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, Self.leading(depth + 1) + 18)
                }
            }
        }
    }
}
