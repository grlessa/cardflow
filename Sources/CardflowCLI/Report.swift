import Foundation
import OffloadKit

public enum Report {
    // fonte única (decimal, igual ao app e ao Finder) — era base 1024 aqui, divergindo do app.
    public static func humanBytes(_ bytes: Int64) -> String { Format.humanBytes(bytes) }

    public static func summary(preview p: OffloadPreview, destinations: [URL]) -> String {
        var lines: [String] = []
        var media = "\(p.photos) foto(s) + \(p.videos) vídeo(s)"
        if p.audios > 0 { media += " + \(p.audios) áudio(s)" }
        if p.cinema > 0 { media += " + \(p.cinema) clipe(s) de cinema" }
        lines.append("Vai copiar: \(media) = \(p.selectedCount) arquivo(s), \(humanBytes(p.totalBytes)) por destino.")
        lines.append("Destinos: " + destinations.map(\.path).joined(separator: ", "))
        if !p.unrecognized.isEmpty {
            lines.append("⚠️ Arquivos não reconhecidos (copiados para .cardflow/desconhecidos): " + p.unrecognized.joined(separator: ", "))
        }
        for s in p.shortfalls {
            lines.append("❌ Sem espaço em \(s.destination.path): precisa \(humanBytes(s.required)), tem \(humanBytes(s.available)).")
        }
        return lines.joined(separator: "\n")
    }

    public static func outcome(_ o: OffloadOutcome) -> String {
        var lines: [String] = []
        lines.append("Verificados: \(o.verifiedCount) · Pulados (já existiam): \(o.skipped.count) · Falhas: \(o.failures.count) · Sidecars: \(o.sidecarsCopied)")
        if o.cardAlreadyCopied { lines.append("Este cartão já tinha sido copiado (nada novo).") }
        if !o.failures.isEmpty { lines.append("Falharam: " + o.failures.joined(separator: ", ")) }
        if !o.unrecognized.isEmpty { lines.append("Não reconhecidos: " + o.unrecognized.joined(separator: ", ")) }
        if !o.relocatedCinema.isEmpty {
            lines.append("⚠️ \(o.relocatedCinema.count) clipe(s) de cinema movido(s) pra evitar sobrescrever filmagem diferente (confira o relink no editor): " + o.relocatedCinema.joined(separator: ", "))
        }
        if !o.manifestFailures.isEmpty {
            lines.append("⚠️ Manifesto NÃO salvo em: " + o.manifestFailures.joined(separator: ", ") + " (a mídia foi verificada; só o registro falhou — disco cheio/somente-leitura?)")
        }
        for p in o.manifestPaths { lines.append("Manifesto: \(p)") }
        return lines.joined(separator: "\n")
    }

    public static func verdict(_ o: OffloadOutcome) -> (ok: Bool, line: String) {
        if o.canSafelyFormatCard {
            return (true, "✅ Tudo verificado em todos os destinos. Pode formatar o cartão com segurança.")
        } else {
            return (false, "❌ \(o.failures.count) falha(s) na verificação. NÃO formate o cartão.")
        }
    }
}
