import Testing
import OffloadKit
@testable import CardflowApp

/// Aviso de nome que pode repetir: sem {contador} nem {nome_original}, dois arquivos geram o mesmo nome
/// e o motor acrescenta data e hora. O editor avisa (sem bloquear).
@MainActor
@Suite struct PresetEditorNameWarningTests {
    private func model(template: String, enabled: Bool = true) -> PresetEditorModel {
        var p = Preset.factoryDefault
        p.rename.enabled = enabled
        p.rename.template = template
        return PresetEditorModel.editing(p)
    }

    @Test func soCameraAvisa() {
        #expect(model(template: "{camera}").nameMayRepeat)
        #expect(model(template: "{evento}_{camera}_{data}").nameMayRepeat)
    }

    @Test func comContadorOuNomeOriginalNaoAvisa() {
        #expect(!model(template: "{evento}_{camera}_{contador}").nameMayRepeat)
        #expect(!model(template: "{camera}_{nome_original}").nameMayRepeat)
    }

    @Test func renomearDesligadoNaoAvisa() {
        #expect(!model(template: "{camera}", enabled: false).nameMayRepeat)
    }
}
