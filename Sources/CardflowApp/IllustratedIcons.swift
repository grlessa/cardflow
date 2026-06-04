import SwiftUI

/// Cartão SD ilustrado (dourado), desenhado em SwiftUI — vetorial, escala junto e segue o tema.
struct SDCardIcon: View {
    var size: CGFloat
    var present: Bool = true

    private var glow: Color { Color(red: 0.93, green: 0.74, blue: 0.30) }

    var body: some View {
        let w = size * 0.76
        let shape = SDCardShape()
        ZStack {
            // corpo
            shape.fill(present
                ? AnyShapeStyle(LinearGradient(
                    colors: [Color(red: 0.98, green: 0.85, blue: 0.46), Color(red: 0.85, green: 0.62, blue: 0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(LinearGradient(
                    colors: [Color.secondary.opacity(0.35), Color.secondary.opacity(0.20)],
                    startPoint: .top, endPoint: .bottom)))
            shape.stroke(Color.black.opacity(present ? 0.18 : 0.10), lineWidth: max(1, size * 0.02))

            // painel de label (área onde se escreve a capacidade) — no miolo/baixo, já que os contatos subiram
            RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                .fill(Color.white.opacity(present ? 0.34 : 0.18))
                .frame(width: w * 0.6, height: size * 0.34)
                .offset(y: size * 0.06)

            // contatos dourados na borda de CIMA (mesma do chanfro), encostando no canto chanfrado.
            // O último (lado do chanfro) é mais estreito — como o pino-chave de um cartão SD real.
            HStack(spacing: w * 0.055) {
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(Color(red: 0.7, green: 0.5, blue: 0.14).opacity(present ? 0.85 : 0.4))
                        .frame(width: i == 5 ? w * 0.038 : w * 0.06, height: size * 0.11)
                }
            }
            .offset(x: w * 0.05, y: -size * 0.30)
        }
        .frame(width: w, height: size)
        .shadow(color: glow.opacity(present ? 0.4 : 0), radius: size * 0.14, y: size * 0.05)
    }
}

/// Contorno do cartão SD: retângulo arredondado com o canto superior direito chanfrado.
struct SDCardShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let c = w * 0.12            // raio dos cantos arredondados
        let cut = w * 0.18          // chanfro (canto sup. direito) — menor, realista
        var p = Path()
        p.move(to: CGPoint(x: c, y: 0))
        p.addLine(to: CGPoint(x: w - cut, y: 0))
        p.addLine(to: CGPoint(x: w, y: cut))
        p.addLine(to: CGPoint(x: w, y: h - c))
        p.addQuadCurve(to: CGPoint(x: w - c, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: c, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - c), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: c))
        p.addQuadCurve(to: CGPoint(x: c, y: 0), control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

/// HD/SSD externo ilustrado — corpo metálico com luz indicadora de acento. Lê bem em tamanho pequeno.
struct DriveIcon: View {
    var size: CGFloat
    var lit: Bool = true
    var body: some View {
        let r = size * 0.22
        ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.56), Color(white: 0.32)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.6, size * 0.03))
            // ranhura/linha de detalhe
            Capsule().fill(Color.black.opacity(0.22))
                .frame(width: size * 0.9, height: max(1, size * 0.05))
                .offset(y: -size * 0.16)
            // luz indicadora
            Circle().fill(lit ? Color.accentColor : Color.secondary)
                .frame(width: size * 0.13, height: size * 0.13)
                .offset(x: size * 0.5, y: size * 0.16)
        }
        .frame(width: size * 1.5, height: size)
    }
}
