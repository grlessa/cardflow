import Testing
import Foundation
@testable import OffloadKit

@Suite struct PresetMigrationTests {
    @Test func presetAntigoComLocaleDecodifica() throws {
        let json = """
        {"schemaVersion":2,"id":"x","name":"N","evento":"E",
         "media":{"mode":"open","lockedTo":"both"},
         "rename":{"enabled":false,"template":"","counterPadding":4,"counterStart":1,"counterStep":1},
         "destinationRoles":["Cópia"],"folderStructure":"{evento}/{tipo}",
         "photoExtensions":["jpg"],"videoExtensions":["mov"],"audioExtensions":[],
         "sidecarExtensions":["xmp"],"copySidecars":"aside","dateFormat":"yyyy-MM-dd",
         "timeFormat":"HHmmss","locale":"pt_BR","sessionFields":[]}
        """
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(p.name == "N")   // chave "locale" extra é ignorada, não lança
    }
}
