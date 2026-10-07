import SwiftUI
import OffloadKit
import CardFormatKit
import CardFormatXPC

/// Textos da formatação (etapas, falhas, sistema de arquivos), usados pela barra de ação.
enum FormatResultSection {
    static func fsName(_ p: FormatPlan) -> String { p.fileSystem == .exfat ? "exFAT" : "FAT32" }

    static func label(_ s: FormatStep) -> String {
        switch s {
        case .validating: return String(localized: "format.step.validating")
        case .unmounting: return String(localized: "format.step.unmounting")
        case .partitioning: return String(localized: "format.step.partitioning")
        case .writingFileSystem: return String(localized: "format.step.writing")
        case .verifying: return String(localized: "format.step.verifying")
        case .remounting: return String(localized: "format.step.remounting")
        }
    }

    static func failure(_ f: FormatFailure) -> String {
        switch f {
        case .unmountFailed, .busy: return String(localized: "format.fail.busy")
        case .cardChanged: return String(localized: "format.fail.cardChanged")
        case .planRejected: return String(localized: "format.fail.unsupported")
        case .deviceRejected: return String(localized: "format.fail.rejected")
        case .diskAccessDenied: return String(localized: "format.fail.diskAccess")
        case .helperUnavailable: return String(localized: "format.fail.helperUnavailable")
        case .writeFailed, .verifyFailed, .fsckFailed, .internalError: return String(localized: "format.fail.incomplete")
        }
    }
}

/// Confirmação: cartão, o que foi conferido e o que vai ser apagado sem cópia (por escolha do operador).
struct FormatConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let card: CardSession

    var body: some View {
        if case .confirming(let report) = card.formatState {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    MediaIllustration(kind: card.volume.mediaKind, size: 52, volumeURL: card.volume.url)
                    Text("format.confirm.title \(card.volume.name)").font(.title3.weight(.semibold))
                }
                Label(String(localized: "format.confirm.verified \(report.saved)"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                if report.excludedTotal > 0 {
                    Label(String(localized: "format.confirm.excluded \(Self.summary(report.excludedByChoice))"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("format.confirm.erases").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("format.confirm.cancel", role: .cancel) { model.cancelFormatConfirmation(card) }
                        .keyboardShortcut(.cancelAction)
                    Button("format.confirm.action", role: .destructive) { Task { await model.confirmFormat(card) } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .padding(24)
            .frame(width: 460)
            .spacedLabels()
        }
    }

    /// "140 fotos, 12 arquivos auxiliares" na ordem fixa dos tipos.
    static func summary(_ m: [FileType: Int]) -> String {
        let order: [(FileType, String)] = [
            (.photo, String(localized: "format.kind.photos")), (.video, String(localized: "format.kind.videos")),
            (.audio, String(localized: "format.kind.audio")), (.cinema, String(localized: "format.kind.cinema")),
            (.sidecar, String(localized: "format.kind.sidecars")), (.unknown, String(localized: "format.kind.other")),
        ]
        return order.compactMap { t, name in m[t].map { "\($0) \(name)" } }.joined(separator: ", ")
    }
}

/// Estado da permissão + ação (onboarding e Ajustes).
struct FormatActivationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.formatter.permission {
            case .ready:
                Label("format.activation.ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsApproval:
                Label("format.activation.needsApproval", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                Spacer()
                Button("format.activation.openSettings") { model.formatter.openSystemSettings() }
            case .notActivated:
                Label("format.activation.off", systemImage: "sdcard")
                Spacer()
                Button("format.activation.activate") { model.formatter.activate() }
            case .unavailable:
                Label("format.activation.unavailable", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .needsDiskAccess:
                VStack(alignment: .leading, spacing: 6) {
                    Label("format.activation.needsDiskAccess", systemImage: "lock.shield").foregroundStyle(.orange)
                    Text("format.activation.diskAccessHelp")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("format.activation.openDiskAccess") { model.formatter.openDiskAccessSettings() }
                        Button("format.activation.revealHelper") { model.formatter.revealHelperInFinder() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.callout)
        // aprovar nos Ajustes do Sistema acontece fora do app: relê ao voltar pra janela
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.formatter.refreshPermission()
        }
    }
}
