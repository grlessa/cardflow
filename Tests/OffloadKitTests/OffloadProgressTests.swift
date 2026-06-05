import Testing
import Foundation
@testable import OffloadKit

@Suite struct OffloadProgressTests {
    private struct Enough: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { .max } }
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func reportsProgressUpToTotal() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(),
                                  clock: { Date(timeIntervalSince1970: 1_780_000_000) },
                                  activityKeeper: NoopActivityKeeper())
        var updates: [OffloadProgress] = []
        _ = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam",
                            onProgress: { updates.append($0) })
        // termina em done com filesDone == filesTotal (3 mídias + 1 sidecar-aside + 1 não-reconhecido
        // copiado como rede de segurança, todos contam no progresso)
        let last = try #require(updates.last)
        #expect(last.phase == .done)
        #expect(last.filesDone == 5)
        #expect(last.filesTotal == 5)
        // progresso é monotônico não-decrescente em filesDone
        #expect(updates.map(\.filesDone) == updates.map(\.filesDone).sorted())
    }
}
