import Testing
import Foundation
@testable import CardFormatXPC
import CardFormatKit

@Suite struct XPCContractTests {
    @Test func requisitosApontamProTimeEOsIdentificadores() {
        #expect(CardFormatXPC.clientRequirement.contains("identifier \"com.cardflow.app\""))
        #expect(CardFormatXPC.clientRequirement.contains("NAS37P6Q53"))
        #expect(CardFormatXPC.helperRequirement.contains("identifier \"com.cardflow.app.formathelper\""))
    }
    @Test func respostaIdaEVolta() throws {
        let plan = try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512)
        let r = FormatResponse(failure: nil, detail: nil, plan: plan)
        #expect(try JSONDecoder().decode(FormatResponse.self, from: JSONEncoder().encode(r)) == r)
        #expect(r.ok)
    }
    @Test func falhaDeAcessoAoDiscoTemNomeProprio() throws {
        let r = FormatResponse(failure: .diskAccessDenied, detail: "errno 1", plan: nil)
        #expect(try JSONDecoder().decode(FormatResponse.self, from: JSONEncoder().encode(r)).failure == .diskAccessDenied)
    }
}
