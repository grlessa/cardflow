import Testing
import Foundation
@testable import OffloadKit

@Suite struct DiskResolverTests {
    @Test func resolvesByUUIDWhenMounted() {
        let mounted = URL(fileURLWithPath: "/Volumes/SSD_NOVO")
        let resolver = DiskResolver(volumes: { [(mounted, "ABCD-1234")] })
        // o caminho antigo é diferente, mas o UUID está montado → usa o atual
        let binding = DiskBinding(volumeUUID: "ABCD-1234", lastKnownPath: "/Volumes/SSD_VELHO")
        #expect(resolver.resolve(binding) == mounted)
    }

    @Test func fallsBackToLastKnownPathWhenUUIDNotMounted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = DiskResolver(volumes: { [] })   // nada montado
        let binding = DiskBinding(volumeUUID: "NAO-MONTADO", lastKnownPath: dir.path)
        #expect(resolver.resolve(binding) == dir)
    }

    @Test func returnsNilWhenNeitherUUIDNorPathAvailable() {
        let resolver = DiskResolver(volumes: { [] })
        let binding = DiskBinding(volumeUUID: "X", lastKnownPath: "/Volumes/inexistente-xyz")
        #expect(resolver.resolve(binding) == nil)
    }

    @Test func readsRealVolumeUUID() {
        // o volume do sistema tem UUID; não deve crashar e deve vir não-nulo
        let uuid = DiskResolver.volumeUUID(at: FileManager.default.temporaryDirectory)
        #expect(uuid != nil)
    }
}
