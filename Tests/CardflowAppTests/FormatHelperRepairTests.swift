import Testing
import Foundation
@testable import CardflowApp
import CardFormatXPC

/// Depois de uma atualização do app, o macOS deixa o registro do ajudante emperrado ("needs LWCR update",
/// saída 78) e não se recupera sozinho. O app registra de novo uma vez por build, e nunca fica esperando
/// para sempre por um ajudante que não sobe.
@Suite struct FormatHelperRepairTests {
    @Test func registraDeNovoQuandoOBuildMudou() {
        #expect(FormatController.shouldReRegister(isEnabled: true, registeredBuild: "312", currentBuild: "373"))
    }

    @Test func registraDeNovoQuandoNuncaAnotouOBuild() {
        // quem atualizou da 1.0.0 (que não anotava) também precisa do novo registro
        #expect(FormatController.shouldReRegister(isEnabled: true, registeredBuild: nil, currentBuild: "373"))
    }

    @Test func naoMexeQuandoOBuildEhOMesmo() {
        #expect(!FormatController.shouldReRegister(isEnabled: true, registeredBuild: "373", currentBuild: "373"))
    }

    @Test func naoRegistraQuemNuncaAtivou() {
        // registrar sem a pessoa pedir faria o macOS mostrar o aviso de item em segundo plano do nada
        #expect(!FormatController.shouldReRegister(isEnabled: false, registeredBuild: nil, currentBuild: "373"))
    }

    @Test func ajudanteSemRespostaTemMensagemPropria() throws {
        // não pode cair no texto de "formatação incompleta": o cartão nem foi tocado
        #expect(FormatResultSection.failure(.helperUnavailable) != FormatResultSection.failure(.internalError))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/CardflowApp/Resources/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let entry = (root["strings"] as! [String: Any])["format.fail.helperUnavailable"] as! [String: Any]
        let locs = entry["localizations"] as! [String: Any]
        func value(_ l: String) -> String {
            ((locs[l] as! [String: Any])["stringUnit"] as! [String: Any])["value"] as! String
        }
        #expect(value("pt-BR").contains("não foi mexido"))
        #expect(value("en").contains("wasn't touched"))
        #expect(value("es").contains("no se tocó"))
    }
}
