import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit

@MainActor @Suite struct HistoryStoreTests {
    func manifest(_ id: String, card: String, at t: TimeInterval) -> Manifest {
        Manifest(schemaVersion: 2, offloadId: id, appVersion: "1.0.0", presetName: "Padrão", camera: "A",
                 startedAt: Date(timeIntervalSince1970: t - 60), finishedAt: Date(timeIntervalSince1970: t),
                 source: .init(volumeName: card, fingerprint: id, fileCount: 1, bytes: 1),
                 destinations: [], files: [], unrecognized: [],
                 totals: .init(photos: 1, videos: 0, audio: 0, sidecars: 0, verified: 1, failed: 0, skipped: 0))
    }
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hist-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func juntaDestinosSemRepetirEMaisRecentePrimeiro() throws {
        let ssd = try tmp(), backup = try tmp()
        defer { try? FileManager.default.removeItem(at: ssd); try? FileManager.default.removeItem(at: backup) }
        let store = ManifestStore()
        try store.write(manifest("aaaa", card: "A001", at: 1_000), eventRootIn: ssd, eventName: "Casamento")
        try store.write(manifest("aaaa", card: "A001", at: 1_000), eventRootIn: backup, eventName: "Casamento")
        try store.write(manifest("bbbb", card: "B002", at: 2_000), eventRootIn: ssd, eventName: "Culto")
        let h = HistoryStore()
        h.reloadNow(destinations: [ssd, backup])
        #expect(h.items.map(\.title) == ["B002", "A001"])
        #expect(h.item("aaaa")?.projectName == "Casamento")
    }
}
