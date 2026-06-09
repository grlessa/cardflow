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

    // exFAT (SSD de cinema): a chave "importantUsage" vem 0 mesmo com disco vazio. Sem o fallback,
    // o disco era reportado com 0 livre e barrava QUALQUER cópia por "sem espaço".
    @Test func exfatUsaDisponivelGenericoQuandoImportantUsageZera() {
        #expect(VolumeFreeSpace.choose(important: 0, generic: 104_632_320) == 104_632_320)
        #expect(VolumeFreeSpace.choose(important: nil, generic: 104_632_320) == 104_632_320)
    }

    // APFS: mantém o número rico (importantUsage), que conta purgeable e costuma ser >= o genérico.
    @Test func apfsMantemNumeroRicoDoImportantUsage() {
        #expect(VolumeFreeSpace.choose(important: 50_000_000_000, generic: 10_000_000_000) == 50_000_000_000)
    }

    // disco realmente cheio em ambas → 0 (sem inventar espaço).
    @Test func ambasZeroContinuaZero() {
        #expect(VolumeFreeSpace.choose(important: 0, generic: 0) == 0)
        #expect(VolumeFreeSpace.choose(important: nil, generic: nil) == 0)
    }
}
