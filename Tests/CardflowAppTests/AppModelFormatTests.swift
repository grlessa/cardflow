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
    /// Formatar e ejetar ao terminar são duas opções independentes: cada combinação tem um fim claro.
    @Test func depoisDeConferirCadaCombinacaoTemUmFim() {
        func next(_ fmt: Bool, _ ej: Bool) -> AppModel.AfterCopy {
            AppModel.afterCopy(safe: true, keptCameras: false, formatOn: fmt, formattingAvailable: true, ejectOn: ej)
        }
        #expect(next(true, true) == .format)    // formata; ejeta depois de formatar
        #expect(next(true, false) == .format)   // formata; fica conectado
        #expect(next(false, true) == .eject)
        #expect(next(false, false) == .stay)    // os dois manuais: fica na tela com os botões
    }

    @Test func semFormatacaoAtivadaSoEjetaSeAOpcaoPedir() {
        #expect(AppModel.afterCopy(safe: true, keptCameras: false, formatOn: true, formattingAvailable: false, ejectOn: true) == .eject)
        #expect(AppModel.afterCopy(safe: true, keptCameras: false, formatOn: true, formattingAvailable: false, ejectOn: false) == .stay)
    }

    @Test func copiaComFalhaNuncaFormataNemEjeta() {
        #expect(AppModel.afterCopy(safe: false, keptCameras: false, formatOn: true, formattingAvailable: true, ejectOn: true) == .stay)
    }

    @Test func cameraDeixadaDeForaEjetaMasNaoFormata() {
        #expect(AppModel.afterCopy(safe: false, keptCameras: true, formatOn: true, formattingAvailable: true, ejectOn: true) == .eject)
        #expect(AppModel.afterCopy(safe: false, keptCameras: true, formatOn: true, formattingAvailable: true, ejectOn: false) == .stay)
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
