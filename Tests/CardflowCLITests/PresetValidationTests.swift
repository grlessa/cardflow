import Testing
import Foundation
@testable import CardflowCLI
@testable import OffloadKit

@Suite struct PresetValidationTests {
    @Test func rejectsPresetWithUnknownTokenBeforeCopying() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let presetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cfp")
        defer { try? FileManager.default.removeItem(at: presetURL) }
        let json = """
        {"schemaVersion":2,"id":"x","name":"X","evento":"X",
         "media":{"mode":"open","lockedTo":"both"},
         "rename":{"enabled":true,"template":"{operdor}_{nome_original}","counterPadding":4},
         "destinationRoles":["Copia"],"folderStructure":"{evento}/{tipo}",
         "photoExtensions":["jpg"],"videoExtensions":["mp4"],"audioExtensions":[],
         "sidecarExtensions":["xml"],"copySidecars":"skip","dateFormat":"yyyy-MM-dd"}
        """
        try Data(json.utf8).write(to: presetURL)
        let cfg = try ArgParser.parse(["--card", card.root.path, "--to", dest.path, "--preset", presetURL.path, "--yes"])

        // erro de validação ANTES de copiar; destino fica vazio
        #expect(throws: PresetStore.PresetError.self) {
            try CardflowRunner.run(cfg, input: { _ in nil }, output: { _ in })
        }
        let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(copied.isEmpty)
    }

    @Test func usesFactoryDefaultWhenNoPreset() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        // sem --preset → preset de fábrica (evento "Sessão", organiza por data)
        let cfg = try ArgParser.parse(["--card", card.root.path, "--to", dest.path, "--yes"])
        try CardflowRunner.run(cfg, input: { _ in nil }, output: { _ in })
        // caminho tem data variável; confirma que caiu sob Sessão/.../Foto/ sem fixar a data.
        let all = (FileManager.default.enumerator(at: dest, includingPropertiesForKeys: nil)?
                       .allObjects as? [URL]) ?? []
        #expect(all.contains { $0.path.contains("/Sessão/") && $0.path.contains("/Foto/") })
    }
}
