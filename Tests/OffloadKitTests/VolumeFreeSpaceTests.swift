import Testing
import Foundation
@testable import OffloadKit

@Suite struct VolumeFreeSpaceTests {
    @Test func availableBytesWorksWhenPathDoesNotExistYet() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // caminho que AINDA não existe (subpasta a criar)
        let notYet = base.appendingPathComponent("evento/FOTO/ainda-nao")
        let bytes = try VolumeFreeSpace().availableBytes(at: notYet)
        #expect(bytes > 0)   // não lança, sobe pro ancestral existente
    }
}
