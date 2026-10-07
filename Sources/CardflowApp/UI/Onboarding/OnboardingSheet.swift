import SwiftUI
import OffloadKit

/// Guia rápido (primeira abertura e menu Ajuda): três passos, cada um com a miniatura da tela de verdade
/// (De | Para, a conferência arquivo por arquivo, o verde que libera formatar) e uma frase só.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: step(title: "onboarding.p1.title", text: "onboarding.p1.text") { RouteMini() }
                case 1: step(title: "onboarding.p2.title", text: "onboarding.p2.text") { VerifyMini() }
                default: step(title: "onboarding.p3.title", text: "onboarding.p3.text") {
                    VStack(spacing: 14) {
                        DoneMini()
                        FormatActivationRow().frame(maxWidth: 380)
                    }
                }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                .animation(.smooth(duration: 0.25), value: page)
                .accessibilityElement()
                .accessibilityLabel(Text("onboarding.a11y.page \(page + 1)"))
                Spacer()
                if page > 0 { Button("onboarding.back") { withAnimation(.smooth(duration: 0.3)) { page -= 1 } } }
                Button(page < 2 ? "onboarding.next" : "onboarding.cta") {
                    if page < 2 { withAnimation(.smooth(duration: 0.3)) { page += 1 } } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560)
        .clipped()
        .spacedLabels()
    }

    private func step<Art: View>(title: LocalizedStringKey, text: LocalizedStringKey, @ViewBuilder art: () -> Art) -> some View {
        VStack(spacing: 18) {
            art().padding(.top, 34)
            Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Miniaturas

/// Moldura das miniaturas: o mesmo painel das telas do app.
private struct MiniPanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(16)
            .frame(width: 420)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6)))
            .accessibilityHidden(true)
    }
}

/// Passo 1: De | Para, como no topo do cartão.
private struct RouteMini: View {
    var body: some View {
        MiniPanel {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("route.from").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    MediaIllustration(kind: .sd, size: 52)
                    Text(verbatim: "A001").font(.headline)
                    Text(verbatim: "64 GB").font(.title3.weight(.semibold)).foregroundStyle(.tint)
                }
                .frame(width: 110, alignment: .leading)
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 8) {
                    Text("route.to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        MediaIllustration(kind: .ssd, size: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(verbatim: "SSD").font(.headline)
                                RoleTag(role: .principal)
                            }
                            GeometryReader { g in
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: g.size.width * 0.42)
                                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * 0.12)
                                    Spacer(minLength: 0)
                                }
                                .background(.quaternary).clipShape(Capsule())
                            }
                            .frame(height: 6)
                        }
                    }
                    .padding(10)
                    .background(.background, in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            .fixedSize(horizontal: false, vertical: true)   // a divisória vertical não estica o quadro
        }
    }
}

/// Passo 2: arquivos ganhando o visto um a um enquanto a barra enche.
private struct VerifyMini: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let names = ["C0001.MP4", "C0002.MP4", "C0003.MP4", "C0004.MP4"]

    var body: some View {
        MiniPanel {
            TimelineView(.periodic(from: .now, by: 0.7)) { ctx in
                let step = reduceMotion ? names.count : Int(ctx.date.timeIntervalSinceReferenceDate / 0.7) % (names.count + 2)
                let done = min(step, names.count)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                        HStack(spacing: 8) {
                            Image(systemName: i < done ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(i < done ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                            Text(verbatim: n).font(.system(.callout, design: .monospaced))
                                .foregroundStyle(i < done ? .primary : .secondary)
                            Spacer()
                            if i < done {
                                Text("onboarding.mini.verified").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ProgressView(value: Double(done), total: Double(names.count))
                        .tint(done == names.count ? .green : .accentColor)
                        .animation(.smooth(duration: 0.4), value: done)
                }
            }
        }
    }
}

/// Passo 3: a barra de ação no verde, com Formatar.
private struct DoneMini: View {
    var body: some View {
        MiniPanel {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("action.verified").font(.headline)
                    Text("onboarding.mini.verifiedDetail").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("format.button")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
        }
    }
}
