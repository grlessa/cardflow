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

    // #14: o arquivo copiado preserva a data de modificação da origem (uma cópia do Finder faz isso;
    // sem isto tudo ficaria datado do momento do offload, quebrando ordenar-por-data e ficando PIOR que o Finder).
    @Test func preservesSourceModificationDate() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let src = work.appendingPathComponent("clip.mov")
        try Data("conteudo-do-clipe".utf8).write(to: src)
        let past = Date(timeIntervalSince1970: 1_700_000_000)   // data antiga determinística
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: src.path)

        let dest = work.appendingPathComponent("out/clip.mov")
        _ = try FileCopier().copy(source: src, to: [dest])

        let destMod = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(destMod != nil)
        #expect(abs((destMod ?? .distantPast).timeIntervalSince(past)) < 1)
    }

    @Test func reportsChunkProgressSummingToFileSize() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let src = work.appendingPathComponent("big.bin")
        let payload = Data((0..<10_000).map { UInt8($0 & 0xFF) })   // 10 KB
        try payload.write(to: src)
        let dest = work.appendingPathComponent("out/big.bin")

        var reported = 0
        var calls = 0
        let copier = FileCopier(chunkSize: 1024)   // força vários blocos (10 KB / 1 KB ≈ 10)
        _ = try copier.copy(source: src, to: [dest], onChunk: { reported += $0; calls += 1 })

        #expect(reported == payload.count)   // a soma dos blocos = tamanho do arquivo
        #expect(calls > 1)                    // reportou DURANTE o arquivo, não só no fim
    }
}
