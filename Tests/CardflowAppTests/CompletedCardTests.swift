import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit
import CardFormatKit

/// O cartão que sai do Mac depois de terminar deixa um resumo na tela (o que aconteceu e a que horas),
/// pra quem volta do café não cair numa tela vazia sem saber se deu certo.
@MainActor @Suite struct CompletedCardTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_300_000)

    private func card(selected: Int = 12, bytes: Int64 = 22_210_000_000, alreadyThere: Int = 0) -> CardSession {
        let c = CardSession(volume: ExternalVolume(url: URL(fileURLWithPath: "/Volumes/A001"), name: "A001",
                                                   isRemovable: true, isInternal: false))
        c.scanned = []
        c.phase = .ready
        var pv = OffloadPreview(photos: 0, videos: selected, audios: 0, cinema: 0, junk: 0, selectedCount: selected,
                                totalBytes: bytes, unrecognized: [], shortfalls: [])
        pv.alreadyPresent = alreadyThere
        c.preview = pv
        return c
    }

    @Test func copiadoFormatadoEEjetadoMostraAsQuatroEtapas() throws {
        let c = card()
        c.phase = .finished(OffloadOutcome(verifiedCount: 12, failures: [], unrecognized: [], skipped: [],
                                           manifestPaths: ["/x/manifest.json"]))
        c.finishedAt = t0
        c.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        c.formattedAt = t0.addingTimeInterval(60)
        c.ejected = true
        c.ejectedAt = t0.addingTimeInterval(65)

        let done = try #require(CompletedCard.make(from: c, destinations: [URL(fileURLWithPath: "/Volumes/eLESSA_03")]))
        #expect(done.steps.map(\.kind) == [.copied, .verified, .formatted, .ejected])
        #expect(done.steps.map(\.at) == [t0, t0, t0.addingTimeInterval(60), t0.addingTimeInterval(65)])
        #expect(done.verdict == .ready)
        #expect(done.fileSystem == "exFAT")
        #expect(done.files == 12)
        #expect(done.bytes == 22_210_000_000)
        #expect(done.manifestPaths == ["/x/manifest.json"])
        #expect(done.name == "A001")
    }

    @Test func cartaoQueJaEstavaNoDestinoEFoiEjetado() throws {
        let c = card(selected: 1, alreadyThere: 1)
        c.ejected = true
        c.ejectedAt = t0
        let done = try #require(CompletedCard.make(from: c, destinations: []))
        #expect(done.steps.map(\.kind) == [.alreadyThere, .ejected])
        #expect(done.verdict == .ready)
    }

    @Test func cartaoQueSaiuSemNadaAcontecerNaoDeixaResumo() {
        // tirado do Mac antes de copiar: não é "concluído"
        #expect(CompletedCard.make(from: card(), destinations: []) == nil)
    }

    @Test func copiaComFalhaNaoViraConcluido() {
        let c = card()
        c.phase = .finished(OffloadOutcome(verifiedCount: 11, failures: ["C0003.MP4"], unrecognized: [], skipped: []))
        c.ejected = true
        #expect(CompletedCard.make(from: c, destinations: []) == nil)
    }

    @Test func cameraDeixadaNoCartaoAvisaParaNaoFormatar() throws {
        let c = card()
        c.phase = .finished(OffloadOutcome(verifiedCount: 8, failures: [], unrecognized: [], skipped: [], cameraFilesLeft: 4))
        c.finishedAt = t0
        c.ejected = true
        c.ejectedAt = t0
        let done = try #require(CompletedCard.make(from: c, destinations: []))
        #expect(done.verdict == .keepCard)
        #expect(!done.steps.map(\.kind).contains(.formatted))
    }

    @Test func cartaoQueSaiDepoisDeTerminarFicaSelecionadoComoConcluido() {
        let m = AppModel.withTestCard(name: "A001")
        let c = m.cards[0]
        c.phase = .finished(OffloadOutcome(verifiedCount: 3, failures: [], unrecognized: [], skipped: []))
        c.finishedAt = t0
        c.ejected = true
        m.selection = .card(c.id)
        m.selectionByUser = true
        m.syncCards(with: [])
        #expect(m.completed.count == 1)
        #expect(m.selection == .completed(m.completed[0].id))
        m.dismissCompleted(m.completed[0].id)
        #expect(m.completed.isEmpty)
        #expect(m.selection == nil)
    }

    // MARK: Ao vivo (cartão ainda conectado)

    private func finished() -> CardSession {
        let c = card()
        c.phase = .finished(OffloadOutcome(verifiedCount: 12, failures: [], unrecognized: [], skipped: []))
        c.finishedAt = t0
        return c
    }

    @Test func conectadoSemFormatarNemEjetarMostraOsDoisPendentes() throws {
        let s = try #require(CompletedCard.make(from: finished(), destinations: [], live: true, formattingAvailable: true))
        #expect(s.steps.map(\.kind) == [.copied, .verified, .formatted, .ejected])
        #expect(s.steps.map(\.state) == [.done, .done, .pending, .pending])
    }

    @Test func formatandoAparecemEmAndamento() throws {
        let c = finished()
        c.formatState = .formatting(.writingFileSystem)
        let s = try #require(CompletedCard.make(from: c, destinations: [], live: true, formattingAvailable: true))
        #expect(s.steps.first { $0.kind == .formatted }?.state == .running)
    }

    @Test func formatadoMasAindaConectadoSoFaltaEjetar() throws {
        let c = finished()
        c.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        c.formattedAt = t0
        let s = try #require(CompletedCard.make(from: c, destinations: [], live: true, formattingAvailable: true))
        #expect(s.steps.map(\.state) == [.done, .done, .done, .pending])
    }

    @Test func semFormatacaoAtivadaNaoMostraEtapaDeFormatar() throws {
        let s = try #require(CompletedCard.make(from: finished(), destinations: [], live: true, formattingAvailable: false))
        #expect(s.steps.map(\.kind) == [.copied, .verified, .ejected])
    }

    @Test func cartaoJaCopiadoSemNadaFeitoContinuaNaTelaNormal() {
        // conectado, tudo já no destino e nada feito agora: a tela de sempre ("Tudo já está no destino")
        #expect(CompletedCard.make(from: card(selected: 1, alreadyThere: 1), destinations: [], live: true,
                                   formattingAvailable: true) == nil)
    }
}
