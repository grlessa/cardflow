import Testing
import Foundation
@testable import OffloadKit

/// Cobre a API pública que o editor de preset (Plano 6) consome:
/// catálogo de tokens ordenado e a prévia ao vivo do nome.
@Suite struct PresetEditorPreviewTests {
    let tz = TimeZone(identifier: "America/Sao_Paulo")!  // amostra: 2026-05-28 17:26:40 -03

    /// O picker mostra UM chip por token conhecido — nem a mais, nem a menos.
    /// Se alguém adicionar um token no motor sem listar aqui, este teste pega.
    @Test func tokenOrderCobreTodosOsTokensConhecidos() {
        #expect(Set(NameBuilder.tokenOrder) == NameBuilder.knownTokens)
        #expect(NameBuilder.tokenOrder.count == NameBuilder.knownTokens.count)  // sem duplicatas
    }

    @Test func modificadoresExpostos() {
        #expect(NameBuilder.knownModifiers == ["maiuscula", "minuscula"])
    }

    /// Prévia de um template válido devolve pasta/nome renderizados pelo motor real.
    @Test func previaRenderizaTemplateValido() {
        var preset = Preset.factoryDefault
        preset.evento = "Culto"
        preset.folderStructure = "{evento}/{ano}-{mes}"
        preset.rename = .init(enabled: true, template: "{evento}_{contador}", counterPadding: 4)
        let nb = NameBuilder(preset: preset, timeZone: tz)

        let result = nb.preview(for: .previewSample, context: .previewContext)
        #expect(result == .success("Culto/2026-05/Culto_0001.JPG"))
    }

    /// Sem renome, a prévia mantém o nome original do arquivo de exemplo.
    @Test func previaSemRenomeMantemNomeOriginal() {
        var preset = Preset.factoryDefault
        preset.evento = "Evento"
        preset.folderStructure = "{evento}/{tipo}"
        preset.rename.enabled = false
        let nb = NameBuilder(preset: preset, timeZone: tz)

        let result = nb.preview(for: .previewSample, context: .previewContext)
        #expect(result == .success("Evento/FOTO/DSC00001.JPG"))
    }

    /// Token desconhecido não estoura — vira erro mostrável na UI.
    @Test func previaSurfaceiaTokenDesconhecido() {
        var preset = Preset.factoryDefault
        preset.folderStructure = "{evento}/{naoexiste}"
        let nb = NameBuilder(preset: preset, timeZone: tz)

        let result = nb.preview(for: .previewSample, context: .previewContext)
        #expect(result == .failure(.unknownToken("naoexiste")))
    }

    /// Campo de sessão declarado é aceito na prévia (resolve mesmo sem valor).
    @Test func previaAceitaCampoDeSessaoDeclarado() {
        var preset = Preset.factoryDefault
        preset.evento = "X"
        preset.sessionFields = [.init(key: "operador", label: "Operador")]
        preset.folderStructure = "{evento}/{operador}"
        preset.rename.enabled = false
        let nb = NameBuilder(preset: preset, timeZone: tz)

        let result = nb.preview(for: .previewSample,
                                context: .init(camera: "Cam", counter: 1, sessionValues: ["operador": "Ana"]))
        #expect(result == .success("X/Ana/DSC00001.JPG"))
    }

    /// A amostra tem campos realistas (foto Sony) pra prévia fazer sentido.
    @Test func amostraDePreviaEhRealista() {
        #expect(MediaFile.previewSample.type == .photo)
        #expect(MediaFile.previewSample.relPath == "DCIM/100MSDCF/DSC00001.JPG")
    }
}
