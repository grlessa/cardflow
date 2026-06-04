import Testing
import Foundation
@testable import OffloadKit

@Suite struct SessionFieldOffloadTests {
    private struct Enough: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { .max } }
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func renamesUsingCameraSessionFieldAndCardName() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }

        var preset = Preset.sampleConferencia
        preset.sessionFields = [.init(key: "operador", label: "Operador")]
        preset.rename = .init(enabled: true, template: "{operador}_{nome_original}", counterPadding: 4)
        preset.folderStructure = "{evento}/{tipo}"

        let service = CopyService(preset: preset, spaceProvider: Enough(),
                                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!,
                                  clock: { Date(timeIntervalSince1970: 1_780_000_000) },
                                  activityKeeper: NoopActivityKeeper())
        let outcome = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest],
                                      camera: "Cam01", sessionValues: ["operador": "Joao"])
        #expect(outcome.failures.isEmpty)
        // arquivo renomeado com o campo de sessão
        let foto = dest.appendingPathComponent("Conferencia-Junho-2026/FOTO/Joao_DSC00001.JPG")
        #expect(FileManager.default.fileExists(atPath: foto.path))
    }
}
