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
    public struct Shortfall: Equatable, Sendable {
        public let destination: URL
        public let required: Int64
        public let available: Int64
    }

    private let provider: FreeSpaceProviding
    public init(provider: FreeSpaceProviding) { self.provider = provider }

    /// Cada destino recebe o payload inteiro; destinos no mesmo volume físico somam o espaço exigido.
    public func check(requiredBytesPerDestination: Int64, destinations: [URL], marginBytes: Int64) throws -> [Shortfall] {
        let items = destinations.map { (destination: $0, required: requiredBytesPerDestination, margin: marginBytes) }
        return try checkPerDestination(items)
    }

    /// Checa requisitos diferentes por destino, agregando destinos que compartilham o mesmo volume.
    public func checkPerDestination(_ items: [(destination: URL, required: Int64, margin: Int64)]) throws -> [Shortfall] {
        var volumeKeyFor: [URL: String] = [:]
        var groupedRequired: [String: Int64] = [:]
        var groupedMargin: [String: Int64] = [:]
        for item in items {
            let key = Self.volumeIdentityKey(for: item.destination)
            volumeKeyFor[item.destination] = key
            groupedRequired[key, default: 0] += item.required
            groupedMargin[key] = max(groupedMargin[key] ?? 0, item.margin)
        }
        var shortfalls: [Shortfall] = []
        for item in items {
            let key = volumeKeyFor[item.destination]!
            let needed = (groupedRequired[key] ?? item.required) + (groupedMargin[key] ?? item.margin)
            let available = try provider.availableBytes(at: item.destination)
            if available < needed {
                shortfalls.append(Shortfall(destination: item.destination, required: needed, available: available))
            }
        }
        return shortfalls
    }

    private static func volumeIdentityKey(for url: URL) -> String {
        let fm = FileManager.default
        let std = url.standardizedFileURL
        var dir = std
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Caminhos fictícios sob `/Volumes/<inexistente>` ou `/` que não existem não devem colapsar
        // todos no volume raiz `/` (evita somar destinos virtuais distintos em testes/simulações).
        if !fm.fileExists(atPath: std.path) && (dir.path == "/" || dir.path == "/Volumes") {
            return "path:\(std.path)"
        }
        if let vals = try? dir.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]) {
            if let uuid = vals.volumeUUIDString, !uuid.isEmpty { return "uuid:\(uuid)" }
            if let vol = vals.volume { return "vol:\(vol.standardizedFileURL.path)" }
        }
        return "path:\(std.path)"
    }
}
