import Testing
import Foundation
@testable import CardFormatKit

@Suite struct BlockDeviceTests {
    @Test func escreveLeZeraEmArquivoEsparso() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileBlockDevice.createSparse(at: path, sectors: 1 << 26)   // 32 GiB, esparso
        #expect(dev.sectorCount == 1 << 26)
        try dev.write(sector: 100, [UInt8](repeating: 0xAB, count: 1024))
        #expect(try dev.read(sector: 100, count: 2) == [UInt8](repeating: 0xAB, count: 1024))
        try dev.zero(sector: 101, count: 1)
        #expect(try dev.read(sector: 101, count: 1) == [UInt8](repeating: 0, count: 512))
        #expect(throws: BlockDeviceError.self) { try dev.write(sector: 0, [1, 2, 3]) }
        dev.close()
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! UInt64
        #expect(size == UInt64(1 << 26) * 512)
    }
}
