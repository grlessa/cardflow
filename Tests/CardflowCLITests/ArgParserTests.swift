import Testing
@testable import CardflowCLI
@testable import OffloadKit

@Suite struct ArgParserTests {
    @Test func parsesFullInvocation() throws {
        let c = try ArgParser.parse([
            "--card", "/Volumes/SONY", "--to", "/Volumes/SSD", "--to", "/Volumes/HD",
            "--media", "video", "--camera", "Cam01", "--evento", "Conf-2026",
            "--rename", "--dry-run", "--yes", "--preset", "p.json",
        ])
        #expect(c.card == "/Volumes/SONY")
        #expect(c.destinations == ["/Volumes/SSD", "/Volumes/HD"])
        #expect(c.media == .video)
        #expect(c.camera == "Cam01")
        #expect(c.evento == "Conf-2026")
        #expect(c.renameOverride == true)
        #expect(c.dryRun == true)
        #expect(c.assumeYes == true)
        #expect(c.presetPath == "p.json")
    }

    @Test func minimalInvocationUsesDefaults() throws {
        let c = try ArgParser.parse(["--card", "/Volumes/SONY", "--to", "/Volumes/SSD"])
        #expect(c.media == .both)
        #expect(c.camera == "Cam")
        #expect(c.evento == nil)
        #expect(c.renameOverride == nil)
        #expect(c.dryRun == false)
        #expect(c.assumeYes == false)
        #expect(c.presetPath == nil)
    }

    @Test func missingCardThrows() {
        #expect(throws: CLIError.self) { _ = try ArgParser.parse(["--to", "/x"]) }
    }

    @Test func missingDestinationThrows() {
        #expect(throws: CLIError.self) { _ = try ArgParser.parse(["--card", "/x"]) }
    }

    @Test func badMediaThrows() {
        #expect(throws: CLIError.self) { _ = try ArgParser.parse(["--card", "/x", "--to", "/y", "--media", "xyz"]) }
    }

    @Test func parsesAudioMedia() throws {
        let c = try ArgParser.parse(["--card", "/x", "--to", "/y", "--media", "audio"])
        #expect(c.media == .audio)
    }

    @Test func parsesSessionFields() throws {
        let c = try ArgParser.parse([
            "--card", "/c", "--to", "/d", "--set", "operador=Joao", "--set", "local=Templo",
        ])
        #expect(c.sessionValues["operador"] == "Joao")
        #expect(c.sessionValues["local"] == "Templo")
    }

    @Test func badSetThrows() {
        #expect(throws: CLIError.self) { _ = try ArgParser.parse(["--card", "/c", "--to", "/d", "--set", "semsinal"]) }
    }
}
