// Gera o fundo do DMG de instalação: gradiente claro + curvas de nível (azul da marca, via
// marching squares) + seta colorida apontando do app pro Applications. Saída: PNG @2x (1320×880).
// Uso: swift scripts/make-installer-bg.swift <caminho-de-saida.png>
import AppKit
import CoreGraphics

let scale = 2.0
let Wp = 660.0, Hp = 440.0          // pontos (tamanho da janela do DMG)
let W = Wp*scale, H = Hp*scale      // pixels (@2x, nítido em retina)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 1) gradiente de fundo (branco-azulado → azul bem claro)
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0.96, green: 0.97, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.87, green: 0.91, blue: 1.00, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// 2) curvas de nível via marching squares sobre um campo suave (gaussianas + ondas amplas)
let peaks: [(x: Double, y: Double, a: Double, s: Double)] = [
    (0.16*W, 0.28*H, 1.00, 0.20*W), (0.84*W, 0.72*H, 1.00, 0.22*W),
    (0.50*W, 0.10*H, 0.80, 0.16*W), (0.08*W, 0.78*H, 0.85, 0.17*W),
    (0.94*W, 0.16*H, 0.85, 0.16*W), (0.40*W, 0.95*H, 0.70, 0.15*W),
    (0.70*W, 0.40*H, 0.55, 0.15*W), (0.30*W, 0.60*H, 0.55, 0.15*W),
    (0.62*W, 0.92*H, 0.60, 0.14*W), (0.04*W, 0.40*H, 0.70, 0.15*W)]
func field(_ x: Double, _ y: Double) -> Double {
    var v = 0.0
    for p in peaks { let dx = x-p.x, dy = y-p.y; v += p.a*exp(-(dx*dx+dy*dy)/(2*p.s*p.s)) }
    v += 0.22*sin((x+0.7*y)/210.0) + 0.12*cos((x-1.3*y)/260.0)   // ondas amplas → linhas fluindo
    return v
}
let gx = 240, gy = 160
let cw = W/Double(gx), ch = H/Double(gy)
var g = [[Double]](repeating: [Double](repeating: 0, count: gy+1), count: gx+1)
for i in 0...gx { for j in 0...gy { g[i][j] = field(Double(i)*cw, Double(j)*ch) } }
ctx.setLineWidth(1.4*scale)
ctx.setStrokeColor(CGColor(srgbRed: 0.31, green: 0.66, blue: 1.0, alpha: 0.18))
ctx.setLineCap(.round)
var level0 = 0.0
func t(_ p: Double, _ q: Double) -> Double { let d = q-p; return abs(d) < 1e-9 ? 0.5 : max(0, min(1, (level0 - p)/d)) }
for lv in stride(from: -0.30, through: 1.60, by: 0.052) {
    level0 = lv
    for i in 0..<gx { for j in 0..<gy {
        let x0 = Double(i)*cw, y0 = Double(j)*ch, x1 = x0+cw, y1 = y0+ch
        let a = g[i][j], b = g[i+1][j], c = g[i+1][j+1], d = g[i][j+1]
        var idx = 0
        if a > lv { idx |= 1 }; if b > lv { idx |= 2 }; if c > lv { idx |= 4 }; if d > lv { idx |= 8 }
        let top = CGPoint(x: x0 + cw*t(a,b), y: y0)
        let right = CGPoint(x: x1, y: y0 + ch*t(b,c))
        let bot = CGPoint(x: x0 + cw*t(d,c), y: y1)
        let left = CGPoint(x: x0, y: y0 + ch*t(a,d))
        func seg(_ p: CGPoint, _ q: CGPoint) { ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath() }
        switch idx {
        case 1, 14: seg(left, top); case 2, 13: seg(top, right); case 3, 12: seg(left, right)
        case 4, 11: seg(right, bot); case 6, 9: seg(top, bot); case 7, 8: seg(left, bot)
        case 5: seg(left, top); seg(right, bot); case 10: seg(left, bot); seg(top, right)
        default: break
        }
    } }
}

// 3) seta apontando do app pro Applications. Cor escolhida por argumento (paleta fria, na marca).
let palette = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "azul"
func col(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
let grad: [CGColor]
switch palette {
case "roxo": grad = [col(0.36, 0.62, 1.00), col(0.52, 0.40, 0.96)]   // azul → roxo
case "mono": grad = [col(0.38, 0.68, 1.00), col(0.20, 0.50, 0.96)]   // azul (mono, 2 tons)
default:     grad = [col(0.42, 0.76, 1.00), col(0.20, 0.46, 1.00)]   // azul da marca (claro → fundo)
}
ctx.saveGState()
// origem do CoreGraphics é embaixo-esquerda: ay MAIOR = mais pra cima. 0.56H ≈ 194pt do topo,
// alinhado ao centro dos ícones (que o Finder põe em y=200 do topo).
let ay = 0.56*H
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 0.40*W, y: ay))
arrow.addCurve(to: CGPoint(x: 0.49*W, y: ay),
               control1: CGPoint(x: 0.425*W, y: ay - 0.035*H), control2: CGPoint(x: 0.465*W, y: ay + 0.035*H))
arrow.addCurve(to: CGPoint(x: 0.575*W, y: ay - 0.008*H),
               control1: CGPoint(x: 0.515*W, y: ay - 0.035*H), control2: CGPoint(x: 0.55*W, y: ay - 0.02*H))
let stroked = arrow.copy(strokingWithWidth: 10*scale, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.addPath(stroked); ctx.clip()
let arrowGrad = CGGradient(colorsSpace: cs, colors: grad as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(arrowGrad, start: CGPoint(x: 0.40*W, y: ay), end: CGPoint(x: 0.60*W, y: ay), options: [])
ctx.restoreGState()
let hx = 0.575*W, hy = ay - 0.008*H, hs = 14*scale   // ponta (na cor final do gradiente)
ctx.beginPath()
ctx.move(to: CGPoint(x: hx + hs*1.25, y: hy))
ctx.addLine(to: CGPoint(x: hx - hs*0.35, y: hy + hs))
ctx.addLine(to: CGPoint(x: hx - hs*0.35, y: hy - hs))
ctx.closePath()
ctx.setFillColor(grad.last!)
ctx.fillPath()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "installer-bg.png"
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: Wp, height: Hp)   // 660×440 pt com 1320×880 px = 144 DPI (2x): o Finder
                                           // mostra a imagem inteira no tamanho da janela, nítida em retina.
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✅ fundo do instalador: \(out) (\(Int(W))×\(Int(H)) px @ \(Int(Wp))×\(Int(Hp)) pt)")
