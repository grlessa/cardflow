import Foundation

public protocol FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64
}

/// Provider real: usa a capacidade disponível para uso "importante" do volume.
public struct VolumeFreeSpace: FreeSpaceProviding {
    public init() {}

    /// Escolhe o espaço livre entre as duas chaves. A "importantUsage" é da família APFS (conta
    /// espaço purgeable, dá o número honesto de quanto cabe de verdade) — mas em exFAT/FAT, que é
    /// o formato comum de SSD de cinema (Mac+Windows), ela vem ZERO mesmo com o disco vazio. Aí o
    /// disponível genérico (suportado em todo filesystem) salva. Pega o maior: APFS mantém o número
    /// rico; exFAT usa o genérico em vez de zerar e barrar qualquer cópia por "sem espaço".
    public static func choose(important: Int64?, generic: Int64?) -> Int64 {
        max(important ?? 0, generic ?? 0)
    }

    public func availableBytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        var dir = url
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // chegou na raiz
            dir = parent
        }
        let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                       .volumeAvailableCapacityKey])
        return Self.choose(important: values.volumeAvailableCapacityForImportantUsage,
                           generic: values.volumeAvailableCapacity.map(Int64.init))
    }
}

public struct SpaceChecker {
    public struct Shortfall: Equatable {
        public let destination: URL
        public let required: Int64
        public let available: Int64
    }

    private let provider: FreeSpaceProviding
    public init(provider: FreeSpaceProviding) { self.provider = provider }

    /// Cada destino recebe o payload inteiro; checa um a um. Retorna os que não cabem.
    public func check(requiredBytesPerDestination: Int64, destinations: [URL], marginBytes: Int64) throws -> [Shortfall] {
        let needed = requiredBytesPerDestination + marginBytes
        var shortfalls: [Shortfall] = []
        for dest in destinations {
            let available = try provider.availableBytes(at: dest)
            if available < needed {
                shortfalls.append(Shortfall(destination: dest, required: needed, available: available))
            }
        }
        return shortfalls
    }
}
