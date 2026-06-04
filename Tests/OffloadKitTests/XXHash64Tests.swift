import Testing
import Foundation
@testable import OffloadKit

@Suite struct XXHash64Tests {
    // Vetor canônico do xxHash64: hash de entrada vazia com seed 0.
    @Test func emptyInputCanonicalVector() {
        #expect(XXHash64.hash(Data()) == 0xEF46DB3751D8E999)
    }

    @Test func sameInputSameHash() {
        let data = Data("conferência".utf8)
        #expect(XXHash64.hash(data) == XXHash64.hash(data))
    }

    @Test func differentInputDifferentHash() {
        #expect(XXHash64.hash(Data("a".utf8)) != XXHash64.hash(Data("b".utf8)))
    }

    @Test func seedChangesHash() {
        let data = Data("DSC00001".utf8)
        #expect(XXHash64.hash(data, seed: 0) != XXHash64.hash(data, seed: 1))
    }

    // O caminho incremental (update em pedaços) deve bater com o one-shot,
    // inclusive cruzando o limite de bloco de 32 bytes e com resto não-múltiplo.
    @Test(arguments: [1, 4, 7, 8, 31, 32, 33, 64, 100, 1000])
    func incrementalMatchesOneShot(size: Int) {
        var bytes = [UInt8]()
        for i in 0..<size { bytes.append(UInt8((i * 31 + 7) & 0xFF)) }
        let data = Data(bytes)

        let oneShot = XXHash64.hash(data)

        var hasher = XXHash64()
        var offset = 0
        let chunk = 5 // pedaço propositalmente não alinhado a 32
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            data[offset..<end].withUnsafeBytes { hasher.update($0) }
            offset = end
        }
        #expect(hasher.finalize() == oneShot)
    }

    @Test func fileHashMatchesDataHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("clip.mov")
        let payload = Data((0..<5000).map { UInt8(($0 * 13 + 1) & 0xFF) })
        try payload.write(to: file)

        #expect(try XXHash64.hash(fileAt: file) == XXHash64.hash(payload))
    }
}
