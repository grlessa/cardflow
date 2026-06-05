import SwiftUI

/// Boas-vindas de primeira execução (e reabrível pelo botão de Ajuda). O público são voluntários
/// pouco técnicos que usam o app talvez uma vez por semana e esquecem entre usos — então o guia
/// reforça o fluxo seguro, com ênfase na regra de ouro: só formatar quando ficar verde.
struct OnboardingView: View {
    let onClose: () -> Void

    private struct Passo: Identifiable {
        let id = UUID(); let icon: String; let cor: Color; let titulo: String; let texto: String
    }
    private let passos: [Passo] = [
        .init(icon: "sdcard.fill", cor: .accentColor, titulo: "Conecte o cartão e o disco",
              texto: "Insira o cartão da câmera e ligue o SSD ou HD onde quer salvar a cópia."),
        .init(icon: "externaldrive.fill.badge.checkmark", cor: .accentColor, titulo: "Escolha o destino",
              texto: "O app já sugere o maior disco. Confira, e ligue um disco de backup se quiser uma segunda cópia."),
        .init(icon: "checkmark.shield.fill", cor: .green, titulo: "Inicie e aguarde",
              texto: "Clique em Iniciar. O Cardflow copia e confere cada arquivo byte a byte — não desconecte nada enquanto roda."),
        .init(icon: "checkmark.seal.fill", cor: .green, titulo: "Espere o verde pra formatar",
              texto: "Só formate o cartão quando aparecer “Pode formatar com segurança”. Nunca antes — é o que garante que nada se perdeu."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tint)
                Text("Bem-vindo ao Cardflow").font(.title2.weight(.semibold))
                Text("Copiar os cartões com segurança, em quatro passos").font(.callout).foregroundStyle(.secondary)
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
                            Text("\(i + 1). \(p.titulo)").font(.callout.weight(.semibold))
                            Text(p.texto).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(24)
            Divider()
            Button(action: onClose) {
                Text("Entendi, começar").frame(maxWidth: 240).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
    }
}
