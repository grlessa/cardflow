import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit
import CardFormatKit
import CardFormatXPC

@MainActor final class FakeFormatter: CardFormatting {
    var permission: FormatPermission = .ready
    var requests: [FormatRequest] = []
    var response = FormatResponse(failure: nil, detail: nil, plan: try! FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
    func refreshPermission() {}
    func activate() { permission = .ready }
    func openSystemSettings() {}
    func openDiskAccessSettings() {}
    func revealHelperInFinder() {}
    func format(_ r: FormatRequest, progress: @escaping @MainActor (FormatStep) -> Void) async -> FormatResponse {
        requests.append(r); for s in FormatStep.allCases { progress(s) }; return response
    }
}

@MainActor @Suite struct AppModelFormatTests {
    @Test func comFormatacaoAtivaNaoEjetaSozinho() {
        let fake = FakeFormatter()
        let m = AppModel(formatter: fake)
        #expect(m.shouldAutoEject(canFormat: true) == false)
        fake.permission = .notActivated
        #expect(m.shouldAutoEject(canFormat: true) == true)
        #expect(m.shouldAutoEject(canFormat: false) == false)
    }

    @Test func automaticoComecaDesligado() {
        #expect(AppModel(formatter: FakeFormatter()).autoFormatThisSession == false)
    }

    @Test func avisoDoAutomaticoSoQuandoLigadoEComExclusao() {
        let m = AppModel.withTestCard(formatter: FakeFormatter())
        var pv = OffloadPreview(photos: 0, videos: 1, audios: 0, cinema: 0, junk: 0, selectedCount: 1,
                                totalBytes: 1, unrecognized: [], shortfalls: [])
        pv.excludedByChoice = [.photo: 140]
        m.cards[0].preview = pv
        #expect(m.autoFormatWarning(m.cards[0]) == nil)
        m.autoFormatThisSession = true
        #expect(m.autoFormatWarning(m.cards[0]) == [.photo: 140])
        m.cards[0].preview?.excludedByChoice = [:]
        #expect(m.autoFormatWarning(m.cards[0]) == nil)
    }

    @Test func bloqueioDaTravaNaoChamaOHelper() async {
        let fake = FakeFormatter()
        let m = AppModel.withTestCard(formatter: fake)
        m.cards[0].formatState = (.blocked(["DCIM/100/C2.MP4"]))
        await m.confirmFormat(m.cards[0])
        #expect(fake.requests.isEmpty)
        #expect(m.cards[0].formatState == .blocked(["DCIM/100/C2.MP4"]))
    }

    @Test func confirmarSemCartaoConhecidoNaoChamaOHelper() async {
        let fake = FakeFormatter()
        let m = AppModel.withTestCard(formatter: fake)
        m.cards[0].formatState = (.confirming(CardWipeReport()))
        await m.confirmFormat(m.cards[0])
        #expect(fake.requests.isEmpty)
        #expect(m.cards[0].formatState == .failed(.deviceRejected, nil))
    }
}
