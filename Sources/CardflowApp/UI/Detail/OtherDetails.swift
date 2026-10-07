import SwiftUI
import OffloadKit

// MARK: - Vazio

/// Sem cartão: mostra o que dá pra conectar e os três passos, com o guia a um clique.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.cards.isEmpty {
            VStack(spacing: 26) {
                HStack(alignment: .bottom, spacing: 26) {
                    kind(.sd, "empty.kind.card", size: 78)
                    kind(.ssd, "empty.kind.drive", size: 70)
                }
                VStack(spacing: 8) {
                    Text("empty.noCard.title").font(.title2.weight(.semibold))
                    Text("empty.noCard.text").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                HStack(spacing: 8) {
                    stepChip(1, "empty.step.connect", "cable.connector")
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    stepChip(2, "empty.step.choose", "hand.tap")
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    stepChip(3, "empty.step.copy", "checkmark.seal")
                }
                Button { model.showOnboarding = true } label: { Label("empty.guide", systemImage: "play.circle") }
                    .buttonStyle(.borderless)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("empty.pickSomething", systemImage: "sidebar.left",
                                   description: Text("empty.pickSomething.text"))
        }
    }

    private func kind(_ k: MediaKind, _ label: LocalizedStringKey, size: CGFloat) -> some View {
        VStack(spacing: 8) {
            MediaIllustration(kind: k, size: size)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stepChip(_ n: Int, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
            .labelStyle(SpacedLabelStyle())
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(0.7), in: .capsule)
            .accessibilityLabel(Text("empty.step.a11y \(n)") + Text(" ") + Text(title))
    }
}

// MARK: - Destino

struct DestinationDetailView: View {
    @Environment(AppModel.self) private var model
    let volume: ExternalVolume
    @State private var projects: [URL] = []

    var body: some View {
        let role = model.role(of: volume.url)
        let busy = model.cards.contains { $0.isBusy }
        DetailScroll {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    MediaIllustration(kind: volume.mediaKind, size: 72, volumeURL: volume.url)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(volume.name).font(.title2.weight(.semibold)).lineLimit(1)
                            if role != .none { RoleTag(role: role == .principal ? .principal : .backup) }
                        }
                        Text(String(localized: MediaIllustration.name(for: volume.mediaKind)) + (volume.totalBytes.map { " · " + Format.bytes($0) } ?? ""))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let space = DiskSpace(url: volume.url) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProjectedCapacityBar(space: space, adding: 0).frame(height: 10)
                        HStack {
                            Text("dest.used \(Format.bytes(space.total - space.free))")
                            Spacer()
                            Text("dest.free \(Format.bytes(space.free))").foregroundStyle(.primary)
                        }
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .padding(18)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))

            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("dest.section.use")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { roleTiles(role: role, busy: busy).frame(minWidth: 130) }
                    VStack(spacing: 8) { roleTiles(role: role, busy: busy) }
                }
                if role == .backup && model.samePhysicalDisk(volume.url, model.destinationURL) {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: .orange, title: String(localized: "main.dest.backupNotConfirmed"))
                }
            }

            DetailSection("dest.section.projects") {
                if projects.isEmpty {
                    Label("dest.projects.none", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }
                ForEach(projects, id: \.self) { url in
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.title3).foregroundStyle(.tint)
                            Text(url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("result.openInFinder")
                }
            }

            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(volume.url) } label: { Label("menu.card.revealInFinder", systemImage: "folder") }
                if model.customFolders.contains(volume.url) {
                    Button(role: .destructive) { model.forgetDestinationFolder(volume.url) } label: {
                        Label("dest.menu.forget", systemImage: "minus.circle")
                    }
                }
            }
            .controlSize(.large)
        }
        .navigationTitle(volume.name)
        .task(id: volume.url) {
            let url = volume.url
            projects = await Task.detached { Self.projects(in: url) }.value
        }
    }

    @ViewBuilder private func roleTiles(role: AppModel.DestinationRole, busy: Bool) -> some View {
        let backupBlocked = model.samePhysicalDisk(volume.url, model.destinationURL) && role != .principal
        ChoiceTile(symbol: "externaldrive.fill.badge.checkmark", title: "dest.role.principal", detail: "dest.role.principal.short",
                   on: role == .principal) { model.setRole(.principal, for: volume.url) }
            .disabled(busy)
        ChoiceTile(symbol: "externaldrive.fill.badge.plus", title: "dest.role.backup", detail: "dest.role.backup.short",
                   on: role == .backup) { model.setRole(.backup, for: volume.url) }
            .disabled(busy || backupBlocked)
        ChoiceTile(symbol: "nosign", title: "dest.role.none", detail: "dest.role.none.short",
                   on: role == .none) { model.setRole(.none, for: volume.url) }
            .disabled(busy)
    }

    /// Pastas de projeto do Cardflow neste destino (as que têm registro de cópia). Fora do fio principal:
    /// a pasta pode esperar a permissão do macOS.
    nonisolated static func projects(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.filter { fm.fileExists(atPath: $0.appendingPathComponent(".cardflow").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Bloco de escolha com ícone, título e uma frase curta; o escolhido acende no acento.
struct ChoiceTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let on: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol).font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(hovering ? 0.10 : 0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Recente

struct RecentDetailView: View {
    @Environment(AppModel.self) private var model
    let item: RecentOffload

    var body: some View {
        let m = item.manifest
        let tint: Color = item.failed ? .red : (m.interrupted ? .orange : .green)
        DetailScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    MediaIllustration(kind: kind, size: 72, badge: item.failed ? .failed : (m.interrupted ? .warning : .verified))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.title2.weight(.semibold)).lineLimit(1)
                        Text("\(item.projectName) · \(m.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Label { Text(verdict) } icon: {
                            Image(systemName: item.failed ? "xmark.octagon.fill" : (m.interrupted ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                        }
                        .labelStyle(SpacedLabelStyle())
                        .font(.headline).foregroundStyle(tint)
                    }
                    Spacer(minLength: 0)
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(counts, id: \.self) { FactChip(symbol: $0.symbol, text: $0.text) }
                    FactChip(symbol: "internaldrive", text: Format.bytes(bytes))
                    let secs = m.finishedAt.timeIntervalSince(m.startedAt)
                    if secs >= 1 { FactChip(symbol: "timer", text: Format.elapsed(secs)) }
                    if m.totals.skipped > 0 { FactChip(symbol: "checkmark.circle", text: String(localized: "recent.alreadyThere") + " · \(m.totals.skipped)") }
                    if m.totals.failed > 0 { FactChip(symbol: "xmark.circle", text: String(localized: "recent.failed") + " · \(m.totals.failed)", tint: .red) }
                    FactChip(symbol: "folder.badge.gearshape", text: m.presetName)
                    if CameraMetadata.isMeaningful(m.camera) { FactChip(symbol: "camera", text: m.camera) }
                }
                if let f = m.cardFormatted {
                    Label(String(localized: "recent.formatted") + " · " + f.at.formatted(date: .abbreviated, time: .shortened) + " · \(f.fileSystem)",
                          systemImage: "sparkles")
                        .labelStyle(SpacedLabelStyle())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(tint.opacity(0.08), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.25)))

            DetailSection("recent.section.destinations") {
                ForEach(m.destinations, id: \.self) { d in
                    let root = URL(fileURLWithPath: d)
                    let folder = root.appendingPathComponent(item.projectName)
                    Button { NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : root) } label: {
                        HStack(spacing: 11) {
                            if let v = model.volume(root) {
                                MediaIllustration(kind: v.mediaKind, size: 32, volumeURL: v.url)
                            } else {
                                MediaIllustration(kind: d.hasPrefix("/Volumes/") ? .ssd : .folder, size: 32)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.volume(root)?.name ?? root.lastPathComponent).font(.headline)
                                Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("recent.openFolder")
                }
            }

            HStack(spacing: 10) {
                Button { model.openReport(manifestPaths: [item.manifestURL.path]) } label: {
                    Label("recent.openReport", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                Button { NSWorkspace.shared.open(item.projectURL) } label: { Label("recent.openFolder", systemImage: "folder") }
            }
            .controlSize(.large)
        }
        .navigationTitle(item.title)
    }

    private var kind: MediaKind { item.manifest.source.mediaKind.flatMap(MediaKind.init(rawValue:)) ?? .sd }

    private struct Count: Hashable { let symbol: String; let text: String }

    private var counts: [Count] {
        let t = item.manifest.totals
        var out: [Count] = []
        func add(_ n: Int, _ symbol: String, _ one: String, _ many: String) {
            if n > 0 { out.append(.init(symbol: symbol, text: "\(n) " + String(localized: String.LocalizationValue(n == 1 ? one : many)))) }
        }
        add(t.photos, "photo", "noun.photo", "noun.photos")
        add(t.videos, "video", "noun.video", "noun.videos")
        add(t.cinema, "film", "noun.cinemaClip", "noun.cinemaClips")
        add(t.audio, "waveform", "noun.audio", "noun.audios")
        return out
    }

    private var bytes: Int64 {
        item.manifest.files.filter { !$0.destRelPath.contains("/.cardflow/") }.reduce(0) { $0 + $1.bytes }
    }

    private var verdict: LocalizedStringKey {
        if item.failed { return "result.doNotFormat" }
        if item.manifest.interrupted { return "recent.interrupted" }
        return item.manifest.cardFormatted != nil ? "recent.verifiedFormatted" : "action.verified"
    }
}
