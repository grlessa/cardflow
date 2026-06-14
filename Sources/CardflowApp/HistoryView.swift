import SwiftUI
import OffloadKit

/// Histórico de cópias do destino atual — lê os manifestos já gravados. Dá rastreabilidade
/// (o que foi copiado, quando, de qual cartão, com que veredito) sem depender de memória do voluntário.
struct HistoryView: View {
    let manifests: [Manifest]
    let onClose: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "pt-BR")
        f.setLocalizedDateFormatFromTemplate("dd MMM yyyy HH:mm")
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("history.title").font(.title2.weight(.semibold))
                Spacer()
                Button("history.close", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            if manifests.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("history.empty").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(manifests.enumerated()), id: \.offset) { _, m in
                            row(m)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 460)
    }

    private func row(_ m: Manifest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: m.interrupted ? "exclamationmark.triangle.fill"
                  : (m.totals.failed > 0 ? "xmark.octagon.fill" : "checkmark.seal.fill"))
                .foregroundStyle(m.interrupted ? .orange : (m.totals.failed > 0 ? .red : .green))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.presetName).font(.callout.weight(.semibold))
                Text(String(localized: "history.row.dateCard \(Self.dateFmt.string(from: m.finishedAt)) \(m.source.volumeName)"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(resumo(m)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resumo(_ m: Manifest) -> String {
        var p = [String(localized: "history.summary.verified \(m.totals.verified)")]
        if m.totals.skipped > 0 { p.append(String(localized: "history.summary.skipped \(m.totals.skipped)")) }
        if m.totals.failed > 0 { p.append(String(localized: "history.summary.failed \(m.totals.failed)")) }
        if m.interrupted { p.append(String(localized: "history.summary.interrupted")) }
        return p.joined(separator: " · ")
    }
}
