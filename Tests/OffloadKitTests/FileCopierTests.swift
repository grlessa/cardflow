import Testing
import Foundation
@testable import OffloadKit

@Suite struct FileCopierTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func copiesToAllDestinationsAndReturnsSourceHash() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let src = work.appendingPathComponent("C0001.mp4")
        let payload = Data((0..<10_000).map { UInt8(($0 * 3 + 1) & 0xFF) })
        try payload.write(to: src)

        let d1 = work.appendingPathComponent("dest1/E/VIDEO/C0001.mp4")
        let d2 = work.appendingPathComponent("dest2/E/VIDEO/C0001.mp4")

        let copier = FileCopier()
        let hash = try copier.copy(source: src, to: [d1, d2])

        #expect(hash == XXHash64.hash(payload))
        #expect(try Data(contentsOf: d1) == payload)
        #expect(try Data(contentsOf: d2) == payload)
        #expect(try copier.verify(expectedHash: hash, fileAt: d1) == true)
        #expect(try copier.verify(expectedHash: hash, fileAt: d2) == true)
    }

    @Test func verifyDetectsCorruption() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("x.bin")
        try Data((0..<5000).map { UInt8($0 & 0xFF) }).write(to: file)
        let goodHash = try XXHash64.hash(fileAt: file)

        // corrompe 1 byte
        var bytes = try Data(contentsOf: file)
        bytes[100] ^= 0xFF
        try bytes.write(to: file)

        #expect(try FileCopier().verify(expectedHash: goodHash, fileAt: file) == false)
    }
}
