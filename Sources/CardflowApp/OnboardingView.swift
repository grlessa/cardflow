import SwiftUI

/// Boas-vindas de primeira execução (e reabrível pelo botão de Ajuda). O público são voluntários
/// pouco técnicos que usam o app talvez uma vez por semana e esquecem entre usos — então o guia
/// reforça o fluxo seguro, com ênfase na regra de ouro: só formatar quando ficar verde.
struct OnboardingView: View {
    let onClose: () -> Void

    private struct Passo: Identifiable {
        let id = UUID(); let icon: String; let cor: Color; let titulo: LocalizedStringKey; let texto: LocalizedStringKey
    }
    private let passos: [Passo] = [
        .init(icon: "sdcard.fill", cor: .accentColor, titulo: "onboarding.step1.title",
              texto: "onboarding.step1.text"),
        .init(icon: "externaldrive.fill.badge.checkmark", cor: .accentColor, titulo: "onboarding.step2.title",
              texto: "onboarding.step2.text"),
        .init(icon: "folder.fill", cor: .accentColor, titulo: "onboarding.organize.title",
              texto: "onboarding.organize.text"),
        .init(icon: "checkmark.shield.fill", cor: .green, titulo: "onboarding.step3.title",
              texto: "onboarding.step3.text"),
        .init(icon: "checkmark.seal.fill", cor: .green, titulo: "onboarding.step4.title",
              texto: "onboarding.step4.text"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tint)
                Text("onboarding.welcome.title").font(.title2.weight(.semibold))
                Text("onboarding.welcome.subtitle").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 26).padding(.bottom, 18)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(passos.enumerated()), id: \.element.id) { i, p in
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            Circle().fill(p.cor.opacity(0.15)).frame(width: 40, height: 40)
                            Image(systemName: p.icon).foregroundStyle(p.cor).font(.title3)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(verbatim: "\(i + 1). ") + Text(p.titulo)).font(.callout.weight(.semibold))
                            Text(p.texto).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            Divider()
            Button(action: onClose) {
                Text("onboarding.cta").frame(maxWidth: 240).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
    }
}
