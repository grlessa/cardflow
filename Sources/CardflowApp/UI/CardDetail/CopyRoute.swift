import SwiftUI
import OffloadKit

// MARK: - Rota: cartão → destinos

/// A decisão inteira desenhada: o cartão à esquerda, a seta, e cada destino com o espaço que sobra
/// depois desta cópia. Embaixo, o caminho onde os arquivos vão cair. Durante a cópia, a seta enche.
struct CopyRouteView: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // De | Para: o cartão e os discos lado a lado, sem linha ligando (a barra de ação mostra o andamento)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    column("route.from") { source }.frame(width: 150, alignment: .leading)
                    Divider().padding(.horizontal, 18)
                    column("route.to") { destinations }.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    column("route.from") { source }
                    Divider()
                    column("route.to") { destinations }
                }
            }
            if !pathSegments.isEmpty {
                PathChips(disk: model.volume(model.destinationURL), segments: pathSegments)
            }
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))
    }

    private func column<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Cartão

    private var source: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaIllustration(kind: card.volume.mediaKind, size: 64, badge: card.badge, volumeURL: card.volume.url)
            Text(card.volume.name).font(.title3.weight(.semibold)).lineLimit(1)
            if card.preview != nil {
                Text(Format.bytes(card.headlineBytes))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
                Text(sourceCaption)
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(card.phase == .scanning ? "action.scanning" : "main.card.calculating")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if card.isMultiCamera {
                Label(String(localized: "camera.count \(card.cameraEntries.count)"), systemImage: "camera")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .labelStyle(SpacedLabelStyle())
                    .padding(.top, 2)
            } else if model.usesCameraToken {
                CameraField(card: card).padding(.top, 2)
            }
        }
    }

    /// Legenda do número do cartão conforme a fase.
    private var sourceCaption: LocalizedStringKey {
        switch card.phase {
        case .running(let p): "route.copying \(p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0)"
        case .queued: "route.queued"
        case .finished(let o): o.failures.isEmpty ? "route.copied" : "route.toCopy"
        default:
            if card.isAlreadyCopied { "route.alreadyThere" }
            else { card.showsRemainingHeadline ? "route.remaining" : "route.toCopy" }
        }
    }

    // MARK: Destinos

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 8) {
            DestinationNode(card: card, role: .principal)
            if model.backupURL != nil || !backupChoices.isEmpty {
                DestinationNode(card: card, role: .backup)
            }
        }
    }

    private var backupChoices: [ExternalVolume] {
        model.destinations.filter { $0.url != model.destinationURL && !model.samePhysicalDisk($0.url, model.destinationURL) }
    }

    private var pathSegments: [String] { card.pathSegments }
}

// MARK: - Câmera

/// Nome da câmera deste cartão: digitado ou escolhido no menu (CAM A, CAM 1… e a câmera lida dos arquivos).
struct CameraField: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        CameraNameField(name: card.camera, detected: card.detectedCamera) { v in
            card.cameraEdited = true
            card.camera = v
            model.recomputePreview(card)
        }
        .disabled(card.isBusy)
    }
}

/// Campo do nome de uma câmera com menu de nomes comuns (CAM A–D, CAM 1–4) e a câmera lida dos arquivos.
struct CameraNameField: View {
    let name: String
    let detected: String?
    var width: CGFloat = 104
    let onChange: (String) -> Void

    private static let letters = ["CAM A", "CAM B", "CAM C", "CAM D"]
    private static let numbers = ["CAM 1", "CAM 2", "CAM 3", "CAM 4"]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "camera").foregroundStyle(.secondary).font(.caption)
            DeferredTextField("detail.camera", text: Binding(get: { name }, set: onChange))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: width)
            Menu {
                Section { ForEach(Self.letters, id: \.self) { n in Button(n) { onChange(n) } } }
                Section { ForEach(Self.numbers, id: \.self) { n in Button(n) { onChange(n) } } }
                if let detected {
                    Section("camera.detected") { Button(detected) { onChange(detected) } }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("camera.menu.help")
        }
        .help("detail.camera")
    }
}

// MARK: - Câmeras do cartão

/// Cartão que passou por várias câmeras: cada uma com o nome (que vai pros arquivos dela) e a escolha de
/// copiar ou deixar no cartão. Deixar uma de fora trava a formatação (é material de outra pessoa).
struct CameraEntriesView: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        let entries = card.cameraEntries
        let media = model.effectiveMedia(card)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { e in
                // escolhida e com algo do tipo de mídia que vai ser copiado
                let on = !card.excludedCameras.contains(e.id) && Self.hasWanted(e, media)
                HStack(spacing: 10) {
                    Button { toggle(e, entries: entries) } label: {
                        let picked = !card.excludedCameras.contains(e.id)
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(picked ? Color.accentColor : Color.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help(card.excludedCameras.contains(e.id) ? "camera.entry.copy" : "camera.entry.leave")
                    .accessibilityLabel(Text("camera.entry.a11y \(card.cameraName(e))"))
                    .accessibilityValue(Text(card.excludedCameras.contains(e.id) ? "detail.content.leftOnCard" : "camera.entry.copied"))
                    CameraNameField(name: card.cameraName(e), detected: e.detected, width: 130) { v in
                        card.cameraNames[e.id] = v
                        model.recomputePreview(card)
                    }
                    Text(summary(e, on: on))
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(on ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 10))
                .opacity(on ? 1 : 0.7)
            }
            if !card.excludedCameras.isEmpty {
                Label("camera.entry.formatLocked", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .labelStyle(SpacedLabelStyle())
                    .padding(.horizontal, 4)
            }
        }
        .disabled(card.isBusy)
    }

    static func hasWanted(_ e: CameraEntry, _ m: Preset.Media.Kind) -> Bool {
        switch m {
        case .both: e.files > 0
        case .photo: e.photos > 0
        case .video: e.videos > 0
        case .audio: e.audios > 0
        }
    }

    private func toggle(_ e: CameraEntry, entries: [CameraEntry]) {
        if card.excludedCameras.contains(e.id) {
            card.excludedCameras.remove(e.id)
        } else if card.excludedCameras.count < entries.count - 1 {   // pelo menos uma fica
            card.excludedCameras.insert(e.id)
        }
        model.recomputePreview(card)
    }

    private func summary(_ e: CameraEntry, on: Bool) -> String {
        var parts: [String] = []
        if e.videos > 0 { parts.append("\(e.videos) " + String(localized: e.videos == 1 ? "noun.video" : "noun.videos")) }
        if e.photos > 0 { parts.append("\(e.photos) " + String(localized: e.photos == 1 ? "noun.photo" : "noun.photos")) }
        if e.audios > 0 { parts.append("\(e.audios) " + String(localized: e.audios == 1 ? "noun.audio" : "noun.audios")) }
        parts.append(on ? Format.bytes(e.bytes) : String(localized: "detail.content.leftOnCard"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Disco de destino

/// Um destino da rota: ícone, nome, papel e a barra do disco com o pedaço que esta cópia vai ocupar.
/// Clicar troca o disco.
struct DestinationNode: View {
    enum Role { case principal, backup }
    @Environment(AppModel.self) private var model
    let card: CardSession
    let role: Role

    private var url: URL? { role == .principal ? model.destinationURL : model.backupURL }
    /// Quanto esta cópia ainda vai ocupar: só antes de começar (depois, o espaço livre já mostra).
    private var pending: Int64 {
        switch card.phase {
        case .ready, .queued: card.isAlreadyCopied ? 0 : card.headlineBytes
        default: 0
        }
    }
    private var volume: ExternalVolume? { model.volume(url) }

    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            label.accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .disabled(card.isBusy)
        .help(role == .principal ? "route.principal.help" : "route.backup.help")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            DiskPicker(card: card, role: role, pending: pending) { picking = false }
        }
    }

    private func pick(_ u: URL) { role == .principal ? model.setUserDestination(u) : model.setBackup(u) }

    @ViewBuilder private var label: some View {
        if let volume, let url {
            filled(volume, url)
        } else {
            empty
        }
    }

    private func filled(_ v: ExternalVolume, _ url: URL) -> some View {
        let short = model.hasShortfall(url, card: card)
        let space = DiskSpace(url: url)
        return HStack(alignment: .center, spacing: 11) {
            MediaIllustration(kind: v.mediaKind, size: 38, volumeURL: v.url)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(v.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    RoleTag(role: role)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let space {
                    ProjectedCapacityBar(space: space, adding: pending, short: short)
                    Group {
                        if short {
                            Label("route.noSpace", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Text(pending > 0 ? "route.freeAfter \(Format.bytes(max(0, space.free - pending)))"
                                             : "dest.free \(Format.bytes(space.free))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption).monospacedDigit()
                    .labelStyle(SpacedLabelStyle())
                }
            }
        }
        .padding(10)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(short ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.25)))
        .contentShape(.rect(cornerRadius: 12))
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: role == .principal ? "externaldrive.badge.plus" : "plus")
                .font(.title3).foregroundStyle(role == .principal ? Color.accentColor : .secondary)
                .frame(width: 38, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(role == .principal ? "main.dest.pickDisk" : "route.addBackup").font(.headline)
                    .foregroundStyle(role == .principal ? .primary : .secondary)
                Text(role == .principal ? "route.principal.empty" : "route.backup.empty")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            .foregroundStyle(role == .principal ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.4)))
        .contentShape(.rect(cornerRadius: 12))
    }
}

/// Escolha do disco em balão: cada destino com o ícone, o tipo, a barra do disco com o pedaço desta cópia
/// e se cabe. Discos externos primeiro, pastas do Mac depois; no backup, "Nenhum" e o mesmo disco do
/// principal aparece desligado.
struct DiskPicker: View {
    @Environment(AppModel.self) private var model
    let card: CardSession
    let role: DestinationNode.Role
    let pending: Int64
    let done: () -> Void

    private var current: URL? { role == .principal ? model.destinationURL : model.backupURL }

    var body: some View {
        let disks = model.destinations.filter { !$0.isInternalShortcut }
        let folders = model.destinations.filter { $0.isInternalShortcut }
        VStack(alignment: .leading, spacing: 12) {
            Text(role == .principal ? "picker.title.principal" : "picker.title.backup").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if role == .backup {
                        row(symbol: "nosign", title: String(localized: "main.dest.noneOption"),
                            detail: String(localized: "picker.none.detail"), on: current == nil) { model.setBackup(nil) }
                    }
                    if !disks.isEmpty { group("picker.disks", disks) }
                    if !folders.isEmpty { group("main.dest.inComputer", folders) }
                }
            }
            .frame(maxHeight: 380)
            Divider()
            Button { done(); model.requestAddDestination() } label: { Label("sidebar.destinations.add", systemImage: "plus") }
                .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 360)
        .spacedLabels()
    }

    private func group(_ title: LocalizedStringKey, _ vols: [ExternalVolume]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4).padding(.top, 4)
            ForEach(vols) { v in diskRow(v) }
        }
    }

    private func diskRow(_ v: ExternalVolume) -> some View {
        let blocked = role == .backup && (v.url == model.destinationURL || model.samePhysicalDisk(v.url, model.destinationURL))
        let on = v.url == current
        let space = DiskSpace(url: v.url)
        let fits = space.map { $0.free >= pending } ?? true
        return Button {
            if role == .principal { model.setUserDestination(v.url) } else { model.setBackup(v.url) }
            done()
        } label: {
            HStack(spacing: 11) {
                MediaIllustration(kind: v.mediaKind, size: 34, volumeURL: v.url)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(v.name).font(.headline).lineLimit(1).truncationMode(.middle)
                        if model.role(of: v.url) != .none && !on {
                            RoleTag(role: model.role(of: v.url) == .principal ? .principal : .backup)
                        }
                        Spacer(minLength: 4)
                        if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                    if let space {
                        ProjectedCapacityBar(space: space, adding: on || blocked ? 0 : pending, short: !fits)
                        Group {
                            if blocked {
                                Text("picker.sameDisk")
                            } else if !fits {
                                Label("route.noSpace", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            } else if pending > 0 {
                                Text("picker.fits \(Format.bytes(max(0, space.free - pending)))")
                            } else {
                                Text("dest.free \(Format.bytes(space.free))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .labelStyle(SpacedLabelStyle())
                    }
                }
            }
            .padding(10)
            .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.15), lineWidth: on ? 1.5 : 1))
            .contentShape(.rect(cornerRadius: 10))
            .opacity(blocked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(symbol: String, title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); done() } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.secondary).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            .padding(10)
            .background(on ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct RoleTag: View {
    let role: DestinationNode.Role
    var body: some View {
        Text(role == .principal ? "dest.role.principal" : "dest.role.backup")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(role == .principal ? Color.accentColor : .secondary)
            .background(Capsule().fill(role == .principal ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.14)))
    }
}

/// Barra do disco: o que já está ocupado, o pedaço desta cópia (no acento) e o livre.
struct ProjectedCapacityBar: View {
    let space: DiskSpace
    let adding: Int64
    var short = false

    var body: some View {
        GeometryReader { g in
            let total = Double(max(space.total, 1))
            let used = Double(space.total - space.free) / total
            let add = min(Double(adding) / total, max(0, 1 - used))
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: g.size.width * used)
                Rectangle().fill(short ? Color.orange : Color.accentColor).frame(width: max(adding > 0 ? 2 : 0, g.size.width * add))
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(Text("main.capacity.a11yLabel"))
        .accessibilityValue(Text("capacity.freeOf \(Format.bytes(space.free)) \(Format.bytes(space.total))"))
    }
}

// MARK: - Caminho

/// "eLESSA_03 › Projeto › 06 Out 2026 › Vídeo", em etiquetas.
struct PathChips: View {
    let disk: ExternalVolume?
    let segments: [String]
    var label: LocalizedStringKey = "route.goesTo"

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).padding(.trailing, 4)
            if let disk {
                chip { MediaIllustration(kind: disk.mediaKind, size: 14, volumeURL: disk.url); Text(disk.name) }
                separator
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                chip {
                    Image(systemName: "folder.fill").foregroundStyle(.tint).font(.caption)
                    Text(s)
                }
                if i < segments.count - 1 { separator }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: .capsule)
    }
}

// MARK: - O que copiar

/// O que tem no cartão, em blocos que são a própria escolha: o escolhido acende, o resto fica no cartão.
struct MediaTiles: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        let locked = model.workingPreset.media.mode == .locked
        let media = model.effectiveMedia(card)
        VStack(alignment: .leading, spacing: 8) {
            if tiles.isEmpty {
                Text(card.scanned == nil ? "main.card.calculating" : "detail.empty").foregroundStyle(.secondary)
            } else {
                // lado a lado dividindo a linha; em coluna estreita, grade que quebra linha
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { tileButtons(locked: locked, media: media).frame(minWidth: 104) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        tileButtons(locked: locked, media: media)
                    }
                }
            }
            if locked {
                Label(String(localized: "detail.what.locked \(MediaChoiceText.name(model.workingPreset.media.lockedTo))"),
                      systemImage: "lock.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .labelStyle(SpacedLabelStyle())
            }
        }
    }

    private func tileButtons(locked: Bool, media: Preset.Media.Kind) -> some View {
        ForEach(tiles) { t in
            let on = t.kind == .both ? media == .both : (media == .both || media == t.kind)
            Button { model.setMediaChoice(t.kind, for: card) } label: {
                MediaTile(tile: t, on: on, isAll: t.kind == .both)
            }
            .buttonStyle(.plain)
            .disabled(locked || card.isBusy)
        }
    }

    struct Tile: Identifiable {
        let kind: Preset.Media.Kind
        let symbol: String
        let count: Int
        let noun: String
        let bytes: Int64
        var id: String { "\(kind)-\(symbol)" }
    }

    private var tiles: [Tile] {
        let files = card.scanned ?? []
        func group(_ t: FileType) -> [MediaFile] { files.filter { $0.type == t && !$0.preserve } }
        let photos = group(.photo), videos = group(.video), audios = group(.audio)
        let cinemaFiles = files.filter(\.preserve)
        let cinema = Set(cinemaFiles.map { $0.relPath.split(separator: "/").prefix(2).joined(separator: "/") }).count
        func bytes(_ f: [MediaFile]) -> Int64 { f.reduce(0) { $0 + $1.size } }
        var out: [Tile] = []
        if !photos.isEmpty { out.append(.init(kind: .photo, symbol: "photo", count: photos.count, noun: String(localized: photos.count == 1 ? "noun.photo" : "noun.photos"), bytes: bytes(photos))) }
        if !videos.isEmpty { out.append(.init(kind: .video, symbol: "video", count: videos.count, noun: String(localized: videos.count == 1 ? "noun.video" : "noun.videos"), bytes: bytes(videos))) }
        if cinema > 0 { out.append(.init(kind: .video, symbol: "film", count: cinema, noun: String(localized: cinema == 1 ? "noun.cinemaClip" : "noun.cinemaClips"), bytes: bytes(cinemaFiles))) }
        if !audios.isEmpty { out.append(.init(kind: .audio, symbol: "waveform", count: audios.count, noun: String(localized: audios.count == 1 ? "noun.audio" : "noun.audios"), bytes: bytes(audios))) }
        if Set(out.map(\.kind)).count > 1 {
            let all = photos + videos + audios + cinemaFiles
            out.append(.init(kind: .both, symbol: "square.stack.3d.up.fill", count: all.count,
                             noun: String(localized: "route.media.everything"), bytes: bytes(all)))
        }
        return out
    }
}

private struct MediaTile: View {
    let tile: MediaTiles.Tile
    let on: Bool
    let isAll: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: tile.symbol)
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .frame(height: 22)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(tile.count)").font(.title2.weight(.semibold)).monospacedDigit()
                Text(tile.noun).font(.subheadline)
            }
            Text(on || isAll ? Format.bytes(tile.bytes) : String(localized: "detail.content.leftOnCard"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(hovering ? 0.10 : 0.05),
                    in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(on ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.2), lineWidth: on ? 1.5 : 1))
        .opacity(on ? 1 : 0.75)
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Etiquetas soltas

/// Layout que quebra linha (etiquetas de caminho e de detalhes).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // largura finita sempre: devolver infinito (proposta sem limite) desestabiliza a coluna do NSSplitView
        let limit = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let rows = arrange(width: limit ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: limit ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? s.width : rows[rows.count - 1].width + spacing + s.width
            if extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [i], width: s.width, height: s.height))
            } else {
                rows[rows.count - 1].items.append(i)
                rows[rows.count - 1].width = extra
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
            }
        }
        return rows
    }
}

/// Etiqueta de detalhe: ícone e texto numa cápsula (lote, ignorados, não reconhecidos).
struct FactChip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .labelStyle(SpacedLabelStyle())
            .font(.subheadline)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.quaternary.opacity(0.7), in: .capsule)
    }
}

/// Aviso em destaque, com ícone e cor do estado (laranja atenção, vermelho perigo, acento informação).
struct Callout<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                accessory
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 12))
    }
}

extension Callout where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String? = nil) {
        self.symbol = symbol; self.tint = tint; self.title = title; self.detail = detail; self.accessory = EmptyView()
    }
}
