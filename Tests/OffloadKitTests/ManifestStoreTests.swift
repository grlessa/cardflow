import Testing
import Foundation
@testable import OffloadKit

@Suite struct ManifestStoreTests {
    func sampleManifest() -> Manifest {
        Manifest(
            schemaVersion: 2, offloadId: "fp1", appVersion: "0.1.0",
            presetName: "Conf", camera: "Cam01",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_780_000_100),
            source: .init(volumeName: "SONY_64G", fingerprint: "fp1", fileCount: 2, bytes: 4096),
            destinations: ["/Volumes/SSD/Conf"],
            files: [.init(sourceRelPath: "DCIM/1.JPG", destRelPath: "Conf/FOTO/1.JPG",
                          type: .photo, bytes: 2048, xxhash64: "aabb", status: "verified")],
            unrecognized: ["x.dat"],
            totals: .init(photos: 1, videos: 1, audio: 0, sidecars: 0, verified: 2, failed: 0, skipped: 0)
        )
    }

    @Test func writeThenLoadRoundTrips() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let store = ManifestStore()
        let m = sampleManifest()
        let url = try store.write(m, eventRootIn: dest, eventName: "Conf")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try store.loadAll(eventRootIn: dest, eventName: "Conf")
        #expect(loaded.count == 1)
        #expect(loaded.first == m)
    }

    @Test func humanSummaryMentionsTotals() {
        let s = ManifestStore().humanSummary(sampleManifest())
        #expect(s.contains("1 foto"))
        #expect(s.contains("1 vídeo"))
        #expect(s.contains("clipe(s) de cinema"))
        #expect(s.contains("Cam01"))
    }

    @Test func fingerprintIsStableAndOrderIndependent() {
        let a = MediaFile(sourceURL: URL(fileURLWithPath: "/a"), relPath: "B.JPG", size: 10, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        let b = MediaFile(sourceURL: URL(fileURLWithPath: "/b"), relPath: "A.JPG", size: 20, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        #expect(CardFingerprint.compute(files: [a, b]) == CardFingerprint.compute(files: [b, a]))
    }
}
