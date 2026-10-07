import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit
import CardFormatKit

/// O cartão conectado acompanha o que muda nele (arquivo novo, apagado): a lista é relida e a prévia
/// recalculada, sem precisar fechar e abrir o app.
@MainActor @Suite struct CardRescanTests {
    private func file(_ name: String, size: Int64 = 100) -> MediaFile {
        MediaFile(sourceURL: URL(fileURLWithPath: "/Volumes/TESTCARD/DCIM/100/\(name)"), relPath: "DCIM/100/\(name)",
                  size: size, type: .photo, captureDate: Date(timeIntervalSince1970: 0))
    }

    @Test func arquivoNovoNumCartaoProntoAtualizaALista() {
        let m = AppModel.withTestCard()
        let c = m.cards[0]
        c.scanned = [file("A.JPG")]
        #expect(m.applyRescan(c, files: [file("A.JPG"), file("B.JPG")]))
        #expect(c.scanned?.count == 2)
        #expect(c.phase == .ready)
    }

    @Test func releituraSemMudancaNaoMexeEmNada() {
        let m = AppModel.withTestCard()
        let c = m.cards[0]
        c.scanned = [file("A.JPG")]
        #expect(!m.applyRescan(c, files: [file("A.JPG")]))
    }

    @Test func cartaoJaCopiadoQueGanhouArquivosVoltaAProntoParaCopiar() {
        let m = AppModel.withTestCard()
        let c = m.cards[0]
        c.scanned = [file("A.JPG")]
        c.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: []))
        c.finishedAt = Date()
        #expect(m.applyRescan(c, files: [file("A.JPG"), file("B.JPG")]))
        #expect(c.phase == .ready)
        #expect(c.finishedAt == nil)
    }

    @Test func cartaoCopiandoNaoERelido() {
        let m = AppModel.withTestCard()
        let c = m.cards[0]
        c.scanned = [file("A.JPG")]
        c.phase = .queued
        #expect(!m.canRescan(c))
    }

    @Test func cartaoFormatadoNaoERelidoPelaFormatacao() {
        // a formatação troca o volume (outro cartão na lista); a sessão antiga não deve reagir a ela
        let m = AppModel.withTestCard()
        let c = m.cards[0]
        c.formatState = .formatting(.writingFileSystem)
        #expect(!m.canRescan(c))
    }
}

/// Formatar desmonta e remonta o cartão: o volume que volta (mesmo disco físico) é o MESMO cartão, não um
/// cartão novo e vazio. Sem isso a tela pulava pra um "cartão novo" e terminava vazia.
@MainActor @Suite struct FormatRemountTests {
    private func vol(_ name: String, disk: String, uuid: String) -> ExternalVolume {
        ExternalVolume(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, isRemovable: true, isInternal: false,
                       totalBytes: 64_000_000_000, physicalDeviceID: disk, volumeUUID: uuid)
    }

    @Test func formatarRemontarEEjetarTerminaNoResumoDoMesmoCartao() throws {
        let m = AppModel(formatter: FakeFormatter())
        let before = vol("Untitled", disk: "disk4", uuid: "OLD")
        m.syncCards(with: [before])
        let card = try #require(m.cards.first)
        card.scanned = []
        card.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: []))
        card.finishedAt = Date()
        m.selection = .card(card.id)
        m.selectionByUser = true

        card.formatState = .formatting(.unmounting)
        m.syncCards(with: [])                                   // desmontou pra formatar
        #expect(m.cards.count == 1 && m.cards[0] === card)      // não "saiu"
        #expect(m.completed.isEmpty)

        let after = vol("Untitled", disk: "disk4", uuid: "NEW") // volta formatado: outro volume, mesmo disco
        m.syncCards(with: [after])
        #expect(m.cards.count == 1 && m.cards[0] === card)      // nada de cartão novo e vazio
        #expect(m.selection == .card(card.id))

        card.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        card.formattedAt = Date()
        card.ejected = true; card.ejectedAt = Date()
        m.syncCards(with: [])                                   // ejetado
        #expect(m.cards.isEmpty)
        let done = try #require(m.completed.first)
        #expect(done.steps.map(\.kind) == [.copied, .verified, .formatted, .ejected])
        #expect(m.selection == .completed(done.id))
    }

    @Test func formatadoSemEjetarContinuaOMesmoCartaoConectado() throws {
        let m = AppModel(formatter: FakeFormatter())
        m.syncCards(with: [vol("Untitled", disk: "disk4", uuid: "OLD")])
        let card = try #require(m.cards.first)
        card.scanned = []
        card.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: []))
        card.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        card.formattedAt = Date()
        m.syncCards(with: [vol("Untitled", disk: "disk4", uuid: "NEW")])
        #expect(m.cards.count == 1 && m.cards[0] === card)
    }

    @Test func outroCartaoNoMesmoLeitorDepoisDeEjetarEhNovo() throws {
        let m = AppModel(formatter: FakeFormatter())
        m.syncCards(with: [vol("Untitled", disk: "disk4", uuid: "OLD")])
        let card = try #require(m.cards.first)
        card.scanned = []
        card.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        card.ejected = true
        m.syncCards(with: [])
        m.syncCards(with: [vol("B002", disk: "disk4", uuid: "OTHER")])
        #expect(m.cards.count == 1 && m.cards[0] !== card)
    }
}
