import Foundation

public protocol FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64
}

/// Provider real: usa a capacidade disponível para uso "importante" do volume.
public struct VolumeFreeSpace: FreeSpaceProviding {
    public init() {}
    public func availableBytes(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        var dir = url
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // chegou na raiz
            dir = parent
        }
        let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
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
