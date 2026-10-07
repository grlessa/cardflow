import Testing
import Foundation
@testable import OffloadKit

@Suite struct PresetCodableTests {
    @Test func encodeThenDecodeIsIdentity() throws {
        let preset = Preset.sampleConferencia
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == preset)
    }

    // O toggle "Continuar do lote anterior" (counterContinuesAcrossLotes) tem que SOBREVIVER ao salvar/
    // carregar o preset — senão a opção do editor não faz efeito na próxima descarga.
    @Test func counterContinuesAcrossLotesPersiste() throws {
        var preset = Preset.sampleConferencia
        preset.rename = .init(enabled: true, template: "{contador}", counterPadding: 4, counterContinuesAcrossLotes: true)
        let decoded = try JSONDecoder().decode(Preset.self, from: try JSONEncoder().encode(preset))
        #expect(decoded.rename.counterContinuesAcrossLotes == true)
        #expect(decoded == preset)
    }

    @Test func decodesFromSpecShapedJSON() throws {
        let json = """
        {
          "schemaVersion": 2,
          "id": "abc",
          "name": "Conferência Junho 2026",
          "evento": "Conferencia-Junho-2026",
          "media": { "mode": "open", "lockedTo": "both" },
          "rename": { "enabled": false, "template": "{evento}_{camera}_{data}_{hora}_{nome_original}", "counterPadding": 4 },
          "destinationRoles": ["Cópia", "Backup"],
          "folderStructure": "{evento}/{tipo}",
          "photoExtensions": ["jpg","heic","arw"],
          "videoExtensions": ["mp4","mov"],
          "audioExtensions": [],
          "sidecarExtensions": ["xml","thm","xmp"],
          "copySidecars": "aside",
          "dateFormat": "yyyy-MM-dd"
        }
        """
        let preset = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(preset.evento == "Conferencia-Junho-2026")
        #expect(preset.media.mode == .open)
        #expect(preset.copySidecars == .aside)
        #expect(preset.videoExtensions == ["mp4", "mov"])
        // compat: preset SEM timeFormat (versão antiga) decodifica com o padrão — presets antigos não quebram.
        #expect(preset.timeFormat == "HHmmss")
    }
}
