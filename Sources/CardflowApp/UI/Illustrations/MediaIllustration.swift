import SwiftUI
import AppKit
import OffloadKit

/// Selo de estado no canto da ilustração.
enum IllustrationBadge: Equatable {
    case verified, progress(Double), warning, failed
}

/// Ícone de uma mídia, sempre o do macOS: o mesmo que o Finder mostra pro volume conectado (leitor de SD
/// embutido → cartão SD da Apple; disco USB → disco externo), ou, sem volume, o ícone do sistema pro
/// tipo. Nada de desenho próprio de cartão: o do sistema é o que a pessoa já reconhece. Selo de estado
/// no canto.
struct MediaIllustration: View {
    let kind: MediaKind
    let size: CGFloat
    var badge: IllustrationBadge? = nil
    /// Volume conectado: usa o ícone que o Finder dá pra ele.
    var volumeURL: URL? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
            if let badge {
                BadgeView(badge: badge, diameter: max(10, size * 0.38))
                    .offset(x: size * 0.04, y: size * 0.02)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(Self.name(for: kind)))
    }

    private var icon: NSImage {
        if let volumeURL { return NSWorkspace.shared.icon(forFile: volumeURL.path) }
        return Self.systemIcon(for: kind)
    }

    /// Ícones de dispositivo que vêm no macOS, por tipo (os mesmos arquivos que o sistema usa nos volumes).
    static func systemIcon(for kind: MediaKind) -> NSImage {
        let ext = "/System/Library/Extensions/"
        let file: String
        switch kind {
        case .sd: file = ext + "IOSCSIArchitectureModelFamily.kext/Contents/Resources/SD.icns"
        case .ssd, .hdd: file = ext + "IOStorageFamily.kext/Contents/Resources/External.icns"
        case .cfexpressA, .cfexpressB, .cfast, .genericCard, .recorder:
            file = ext + "IOSCSIArchitectureModelFamily.kext/Contents/Resources/Removable.icns"
        case .folder: return NSWorkspace.shared.icon(for: .folder)
        }
        return NSImage(contentsOfFile: file) ?? NSWorkspace.shared.icon(for: .volume)
    }

    static func name(for kind: MediaKind) -> LocalizedStringResource {
        switch kind {
        case .sd: "media.kind.sd"
        case .cfexpressA: "media.kind.cfexpressA"
        case .cfexpressB: "media.kind.cfexpressB"
        case .cfast: "media.kind.cfast"
        case .ssd: "media.kind.ssd"
        case .hdd: "media.kind.hdd"
        case .recorder: "media.kind.recorder"
        case .genericCard: "media.kind.genericCard"
        case .folder: "media.kind.folder"
        }
    }
}

// MARK: - Selo

private struct BadgeView: View {
    let badge: IllustrationBadge
    let diameter: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: .windowBackgroundColor))
            switch badge {
            case .verified:
                Circle().fill(Color.green).padding(diameter * 0.08)
                Image(systemName: "checkmark").font(.system(size: diameter * 0.42, weight: .bold)).foregroundStyle(.white)
            case .warning:
                Circle().fill(Color.orange).padding(diameter * 0.08)
                Image(systemName: "exclamationmark").font(.system(size: diameter * 0.46, weight: .bold)).foregroundStyle(.white)
            case .failed:
                Circle().fill(Color.red).padding(diameter * 0.08)
                Image(systemName: "xmark").font(.system(size: diameter * 0.4, weight: .bold)).foregroundStyle(.white)
            case .progress(let p):
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: diameter * 0.14).padding(diameter * 0.15)
                Circle().trim(from: 0, to: max(0.02, min(1, p)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: diameter * 0.14, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(diameter * 0.15)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.15), radius: diameter * 0.06, y: diameter * 0.03)
    }
}
