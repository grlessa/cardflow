import Testing
import Foundation
@testable import CardflowCLI
@testable import OffloadKit

@Suite struct CardflowRunnerTests {
    func tempDest() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func config(card: URL, dest: URL, dryRun: Bool, yes: Bool) -> CardflowConfig {
        CardflowConfig(card: card.path, destinations: [dest.path], media: .both,
                       camera: "Cam01", evento: "Conf-2026", renameOverride: nil,
                       dryRun: dryRun, assumeYes: yes, presetPath: nil)
    }

    @Test func dryRunDoesNotCopy() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = try tempDest(); defer { try? FileManager.default.removeItem(at: dest) }
        var out: [String] = []
        try CardflowRunner.run(config(card: card.root, dest: dest, dryRun: true, yes: false),
                               input: { _ in nil }, output: { out.append($0) })
        let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(copied.isEmpty)
        #expect(out.joined().contains("Vai copiar"))
    }

    @Test func abortsWhenUserSaysNo() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = try tempDest(); defer { try? FileManager.default.removeItem(at: dest) }
        try CardflowRunner.run(config(card: card.root, dest: dest, dryRun: false, yes: false),
                               input: { _ in "n" }, output: { _ in })
        let copied = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(copied.isEmpty)
    }

    @Test func yesCopiesAndVerifies() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = try tempDest(); defer { try? FileManager.default.removeItem(at: dest) }
        var out: [String] = []
        try CardflowRunner.run(config(card: card.root, dest: dest, dryRun: false, yes: true),
                               input: { _ in nil }, output: { out.append($0) })
        let eventDir = dest.appendingPathComponent("Conf-2026")
        #expect(FileManager.default.fileExists(atPath: eventDir.path))
        #expect(out.joined().contains("Pode formatar"))
    }

    @Test func presetEventoAndRenameNotClobberedWhenFlagsAbsent() throws {
        let card = try FakeCardCLI(); defer { card.cleanup() }
        let dest = try tempDest(); defer { try? FileManager.default.removeItem(at: dest) }
        let presetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: presetURL) }
        let json = """
        {"schemaVersion":2,"id":"x","name":"Culto","evento":"Culto",
         "media":{"mode":"open","lockedTo":"both"},
         "rename":{"enabled":true,"template":"{nome_original}_R","counterPadding":4},
         "destinationRoles":["Copia"],"folderStructure":"{evento}/{tipo}",
         "photoExtensions":["jpg"],"videoExtensions":["mp4","mov"],"audioExtensions":[],
         "sidecarExtensions":["xml"],"copySidecars":"skip","dateFormat":"yyyy-MM-dd"}
        """
        try Data(json.utf8).write(to: presetURL)
        // invocação SEM --evento e SEM --rename → quem manda é o preset
        let cfg = try ArgParser.parse(["--card", card.root.path, "--to", dest.path,
                                       "--preset", presetURL.path, "--yes"])
        try CardflowRunner.run(cfg, input: { _ in nil }, output: { _ in })
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Culto/Foto/DSC00001_R.JPG").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Cardflow").path))
    }
}
