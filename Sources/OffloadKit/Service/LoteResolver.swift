import Foundation

/// Identidade barata de um arquivo pra casar cartão com lote: caminho + tamanho.
/// (Contador resetado pela câmera reusa o nome com tamanho diferente → não casa, vira lote novo.)
public struct LoteFileKey: Hashable, Sendable {
    public let relPath: String
    public let bytes: Int64
    public init(relPath: String, bytes: Int64) { self.relPath = relPath; self.bytes = bytes }
}

/// Um lote já conhecido, derivado dos manifestos do evento.
public struct KnownLote: Equatable, Sendable {
    public let numero: Int
    public let fontes: Set<LoteFileKey>
    public let completo: Bool
    public init(numero: Int, fontes: Set<LoteFileKey>, completo: Bool) {
        self.numero = numero; self.fontes = fontes; self.completo = completo
    }
}

public struct LoteDecision: Equatable, Sendable {
    public let numero: Int
    public let isNovo: Bool
    public let anteriorIncompleto: Int?   // nº do lote anterior incompleto (trava de footage), ou nil
    public init(numero: Int, isNovo: Bool, anteriorIncompleto: Int?) {
        self.numero = numero; self.isNovo = isNovo; self.anteriorIncompleto = anteriorIncompleto
    }
}

public enum LoteResolver {
    /// Decide o lote do cartão atual: casa com o lote conhecido de maior overlap (empate → maior nº);
    /// sem overlap nenhum → lote novo (max+1), sinalizando se o último lote ficou incompleto.
    public static func resolve(cardFiles: Set<LoteFileKey>, known: [KnownLote]) -> LoteDecision {
        var best: (lote: KnownLote, overlap: Int)?
        for k in known {
            let overlap = k.fontes.intersection(cardFiles).count
            guard overlap > 0 else { continue }
            if let b = best {
                if overlap > b.overlap || (overlap == b.overlap && k.numero > b.lote.numero) { best = (k, overlap) }
            } else { best = (k, overlap) }
        }
        if let b = best { return LoteDecision(numero: b.lote.numero, isNovo: false, anteriorIncompleto: nil) }
        let maxNum = known.map(\.numero).max() ?? 0
        let anterior = known.max(by: { $0.numero < $1.numero })
        let incompleto = (anterior?.completo == false) ? anterior?.numero : nil
        return LoteDecision(numero: maxNum + 1, isNovo: true, anteriorIncompleto: incompleto)
    }

    /// Deriva os lotes conhecidos dos manifestos do evento: agrupa por `lote`, une as fontes
    /// (sourceRelPath + bytes), e marca completo pelo manifesto mais recente daquele lote.
    public static func knownLotes(from manifests: [Manifest]) -> [KnownLote] {
        var byLote: [Int: [Manifest]] = [:]
        for m in manifests { if let l = m.lote { byLote[l, default: []].append(m) } }
        return byLote.map { numero, ms in
            let fontes = Set(ms.flatMap { $0.files.map { LoteFileKey(relPath: $0.sourceRelPath, bytes: $0.bytes) } })
            let latest = ms.max(by: { $0.finishedAt < $1.finishedAt })!
            let completo = !latest.interrupted && latest.totals.failed == 0
            return KnownLote(numero: numero, fontes: fontes, completo: completo)
        }
    }
}
