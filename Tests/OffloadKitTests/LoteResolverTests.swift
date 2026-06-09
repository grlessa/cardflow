import Testing
import Foundation
@testable import OffloadKit

@Suite struct LoteResolverTests {
    func key(_ p: String, _ b: Int64) -> LoteFileKey { LoteFileKey(relPath: p, bytes: b) }
    func lote(_ n: Int, _ files: [(String, Int64)], completo: Bool = true) -> KnownLote {
        KnownLote(numero: n, fontes: Set(files.map { key($0.0, $0.1) }), completo: completo)
    }

    @Test func primeiroOffloadSemHistoricoEhLote1() {
        let d = LoteResolver.resolve(cardFiles: [key("C0001.MP4", 100)], known: [])
        #expect(d == LoteDecision(numero: 1, isNovo: true, anteriorIncompleto: nil))
    }

    @Test func cartaoNaoFormatadoCasaMesmoLote() {
        let known = [lote(1, [("C0001.MP4", 100), ("C0002.MP4", 200)])]
        let card: Set = [key("C0001.MP4", 100), key("C0002.MP4", 200), key("C0003.MP4", 300)]
        let d = LoteResolver.resolve(cardFiles: card, known: known)
        #expect(d.numero == 1 && d.isNovo == false)
    }

    @Test func cartaoFormatadoDisjuntoEhLoteNovo() {
        let known = [lote(1, [("C0001.MP4", 100), ("C0002.MP4", 200)])]
        let card: Set = [key("C0003.MP4", 300), key("C0004.MP4", 400)]
        let d = LoteResolver.resolve(cardFiles: card, known: known)
        #expect(d.numero == 2 && d.isNovo == true)
    }

    @Test func contadorResetadoMesmoNomeTamanhoDiferenteEhLoteNovo() {
        let known = [lote(1, [("C0001.MP4", 100)])]
        let card: Set = [key("C0001.MP4", 999)]   // mesmo nome, tamanho diferente → não casa
        let d = LoteResolver.resolve(cardFiles: card, known: known)
        #expect(d.numero == 2 && d.isNovo == true)
    }

    @Test func loteNovoComAnteriorIncompletoSinaliza() {
        let known = [lote(1, [("C0001.MP4", 100)], completo: false)]
        let card: Set = [key("X.MP4", 500)]
        let d = LoteResolver.resolve(cardFiles: card, known: known)
        #expect(d == LoteDecision(numero: 2, isNovo: true, anteriorIncompleto: 1))
    }

    @Test func casaComLoteDeMaiorOverlap() {
        let known = [lote(1, [("A", 1), ("B", 2)]), lote(2, [("C", 3)])]
        let card: Set = [key("A", 1), key("B", 2), key("C", 3)]
        let d = LoteResolver.resolve(cardFiles: card, known: known)
        #expect(d.numero == 1)
    }

    func manifest(lote: Int?, files: [(String, Int64)], interrupted: Bool = false,
                  failed: Int = 0, finishedAt: TimeInterval) -> Manifest {
        Manifest(schemaVersion: 2, offloadId: "fp", appVersion: "x", presetName: "p", camera: "Cam",
                 startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: finishedAt),
                 source: .init(volumeName: "SD", fingerprint: "fp", fileCount: files.count, bytes: 0),
                 destinations: ["/d"],
                 files: files.map { .init(sourceRelPath: $0.0, destRelPath: $0.0, type: .video, bytes: $0.1, xxhash64: "", status: "verified") },
                 unrecognized: [],
                 totals: .init(photos: 0, videos: files.count, audio: 0, sidecars: 0, verified: files.count, failed: failed, skipped: 0),
                 interrupted: interrupted, lote: lote)
    }

    @Test func knownLotesAgrupaUneFontesECalculaCompleto() {
        let ms = [
            manifest(lote: 1, files: [("A", 1)], finishedAt: 10),
            manifest(lote: 1, files: [("B", 2)], finishedAt: 20),                 // mais recente do lote 1, completo
            manifest(lote: 2, files: [("C", 3)], interrupted: true, finishedAt: 30),
            manifest(lote: nil, files: [("Z", 9)], finishedAt: 5),                // sem lote → ignorado
        ]
        let known = LoteResolver.knownLotes(from: ms)
        #expect(known.count == 2)                                                  // o sem-lote não vira lote
        let l1 = known.first { $0.numero == 1 }!
        #expect(l1.fontes == Set([key("A", 1), key("B", 2)]))                      // une as fontes dos 2 manifestos
        #expect(l1.completo == true)                                              // mais recente não interrompido
        #expect(known.first { $0.numero == 2 }!.completo == false)                // interrupted → incompleto
    }
}
