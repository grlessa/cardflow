import SwiftUI
import OffloadKit

/// Barra lateral: Cartões conectados, Destinos e Recentes.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selection }, set: { model.selection = $0; model.selectionByUser = true })) {
            Section("sidebar.cards") {
                if model.cards.isEmpty {
                    Text("sidebar.cards.none")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.cards) { card in
                    CardRow(card: card)
                        .tag(SidebarItem.card(card.id))
                        .contextMenu { CardContextMenu(card: card) }
                }
            }
            Section("sidebar.destinations") {
                ForEach(model.sidebarDestinations) { volume in
                    DestinationRow(volume: volume)
                        .tag(SidebarItem.destination(volume.url))
                        .contextMenu { DestinationContextMenu(volume: volume) }
                }
                Button { model.requestAddDestination() } label: {
                    Label("sidebar.destinations.add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .selectionDisabled()
            }
            if !model.history.items.isEmpty {
                Section("sidebar.recents") {
                    ForEach(model.history.items.prefix(15)) { item in
                        RecentRow(item: item)
                            .tag(SidebarItem.recent(item.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .spacedLabels()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let version = updates.availableVersion {
                    UpdateNotice(version: version)
                }
                SidebarFooter()
            }
        }
    }
}

/// Rodapé fixo da lateral: Ajustes e Apoiar sempre à vista (o ⌘, continua valendo).
struct SidebarFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                SettingsLink {
                    Label("sidebar.settings", systemImage: "gearshape")
                }
                .help("sidebar.settings.help")
                Spacer(minLength: 4)
                Button { NSWorkspace.shared.open(Links.support) } label: {
                    Label("sidebar.support", systemImage: "heart")
                }
                .help("sidebar.support.help")
            }
            .buttonStyle(.borderless)
            .labelStyle(SpacedLabelStyle())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Endereços do site oficial.
enum Links {
    static let site = URL(string: "https://cardflow.lessafilms.com")!
    static let support = URL(string: "https://cardflow.lessafilms.com/apoie/")!
}

extension AppModel {
    /// Destinos mostrados na lateral: discos e pastas escolhidas; Mesa e Documentos só quando estão em
    /// uso ou quando não há outro destino (sugestão pra começar).
    var sidebarDestinations: [ExternalVolume] {
        let all = destinations
        let others = all.filter { !internalShortcuts().contains($0) }
        return all.filter { v in
            guard internalShortcuts().contains(v) else { return true }
            return others.isEmpty || v.url == destinationURL || v.url == backupURL
        }
    }
}

// MARK: - Linhas

struct CardRow: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        HStack(spacing: 10) {
            MediaIllustration(kind: card.volume.mediaKind, size: 30, badge: card.badge, volumeURL: card.volume.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.volume.name).lineLimit(1)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if card.phase == .queued, let pos = model.queuePosition(card) {
            return String(localized: "card.status.queuedAt \(pos)")
        }
        return card.statusLine
    }
    private var statusColor: Color {
        switch card.badge {
        case .verified?: .green
        case .failed?: .red
        case .warning?: .orange
        default: .secondary
        }
    }
}

extension CardSession {
    var badge: IllustrationBadge? {
        if case .done = formatState { return .verified }
        if case .failed = formatState { return .warning }
        switch phase {
        case .running(let p): return .progress(p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0)
        case .finished(let o): return o.canSafelyFormatCard ? .verified : (o.copiedKeepingCameras ? .warning : .failed)
        case .failed(_, let uncertain): return uncertain ? .failed : .warning
        default: return isAlreadyCopied ? .verified : nil
        }
    }
}

struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    let volume: ExternalVolume

    var body: some View {
        let role = model.role(of: volume.url)
        HStack(spacing: 10) {
            MediaIllustration(kind: volume.mediaKind, size: 26, volumeURL: volume.url)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name).lineLimit(1)
                    if role != .none {
                        Text(role == .principal ? "dest.role.principal" : "dest.role.backup")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let space = DiskSpace(url: volume.url) {
                    CapacityLine(space: space)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct RecentRow: View {
    let item: RecentOffload

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text("\(item.projectName) · \(item.manifest.finishedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var symbol: String {
        if item.failed { return "exclamationmark.octagon.fill" }
        if item.manifest.interrupted { return "pause.circle.fill" }
        return item.manifest.cardFormatted != nil ? "checkmark.circle.fill" : "checkmark.seal.fill"
    }
    private var color: Color {
        if item.failed { return .red }
        if item.manifest.interrupted { return .orange }
        return .green
    }
}

// MARK: - Menus de contexto

struct CardContextMenu: View {
    @Environment(AppModel.self) private var model
    let card: CardSession
    var body: some View {
        Button("menu.card.copy") { model.enqueueCopy(card) }.disabled(!model.canStart(card))
        Button("menu.card.format") { model.startFormatFlow(card) }.disabled(!model.canFormat(card))
        Button("menu.card.eject") { Task { await model.eject(card) } }.disabled(card.isBusy)
        Button("menu.card.revealInFinder") { model.revealInFinder(card) }
        Divider()
        Button("menu.card.treatAsDestination") { model.useAsDestination(card.volume) }.disabled(card.isBusy)
    }
}

struct DestinationContextMenu: View {
    @Environment(AppModel.self) private var model
    let volume: ExternalVolume
    var body: some View {
        let role = model.role(of: volume.url)
        Button("dest.menu.usePrincipal") { model.setRole(.principal, for: volume.url) }.disabled(role == .principal)
        Button("dest.menu.useBackup") { model.setRole(.backup, for: volume.url) }
            .disabled(role == .backup || model.samePhysicalDisk(volume.url, model.destinationURL))
        Button("dest.menu.dontUse") { model.setRole(.none, for: volume.url) }.disabled(role == .none)
        Divider()
        Button("menu.card.revealInFinder") { NSWorkspace.shared.open(volume.url) }
        if model.customFolders.contains(volume.url) {
            Button("dest.menu.forget") { model.forgetDestinationFolder(volume.url) }
        }
        if !volume.isInternalShortcut {
            Divider()
            Button("dest.menu.treatAsCard") { model.useAsSource(volume) }
        }
    }
}

// MARK: - Atualização

private struct UpdateNotice: View {
    @EnvironmentObject private var updates: UpdateController
    let version: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("main.update.available \(version)").font(.callout).lineLimit(2)
            Spacer(minLength: 4)
            Button("main.update.install") { updates.install() }
                .controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(10)
    }
}
