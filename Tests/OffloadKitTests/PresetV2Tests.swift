import Testing
import Foundation
@testable import OffloadKit

@Suite struct PresetV2Tests {
    // JSON v2 antigo (sem locale/sessionFields/counterStart) decodifica com defaults.
    @Test func oldJSONDecodesWithDefaults() throws {
        let json = """
        {
          "schemaVersion": 2, "id": "abc", "name": "Conf", "evento": "Conf-2026",
          "media": { "mode": "open", "lockedTo": "both" },
          "rename": { "enabled": false, "template": "{evento}", "counterPadding": 4 },
          "destinationRoles": ["Cópia"], "folderStructure": "{evento}/{tipo}",
          "photoExtensions": ["jpg"], "videoExtensions": ["mp4"], "audioExtensions": [],
          "sidecarExtensions": ["xml"], "copySidecars": "aside", "dateFormat": "yyyy-MM-dd"
        }
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.locale == "pt_BR")
        #expect(p.sessionFields.isEmpty)
        #expect(p.rename.counterStart == 1)
        #expect(p.rename.counterStep == 1)
    }

    @Test func roundTripWithNewFields() throws {
        var p = Preset.sampleConferencia
        p.locale = "pt_BR"
        p.sessionFields = [.init(key: "operador", label: "Operador"), .init(key: "local", label: "Local")]
        p.rename = .init(enabled: true, template: "{contador}", counterPadding: 3, counterStart: 10, counterStep: 5)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == p)
        #expect(decoded.sessionFields.count == 2)
        #expect(decoded.rename.counterStart == 10)
    }
}
