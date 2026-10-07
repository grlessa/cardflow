import Foundation

public enum FileSystemKind: String, Codable, Sendable { case fat32, exfat }

public enum FormatPlanError: Error, Equatable, Sendable {
    case unsupportedSectorSize(Int)
    case legacyCardTooSmall(UInt64)      // ≤ ~2 GB (FAT12/16): formatar na câmera
    case outsideSDARanges(UInt64)        // capacidade num buraco da tabela
}

/// Plano de formatação SDA para um cartão. Offsets de FAT/heap/reservados são RELATIVOS à partição.
public struct FormatPlan: Codable, Equatable, Sendable {
    public let totalSectors: UInt64
    public let fileSystem: FileSystemKind
    public let boundaryUnitSectors: UInt32
    public let sectorsPerCluster: UInt32
    public let partitionStartSector: UInt64
    public let partitionSectorCount: UInt64
    public let partitionType: UInt8
    // exFAT (no FAT32, fatOffset = reservados e clusterHeapOffset = reservados + 2·FAT)
    public let fatOffset: UInt32
    public let clusterHeapOffset: UInt32
    public let clusterCount: UInt32
    // FAT32 (fatLength vale pros dois)
    public let reservedSectors: UInt32
    public let fatLength: UInt32
    public let numberOfFATs: UInt8

    public var clusterBytes: Int { Int(sectorsPerCluster) * 512 }

    public static func make(totalSectors: UInt64, sectorSize: Int) throws -> FormatPlan {
        guard sectorSize == 512 else { throw FormatPlanError.unsupportedSectorSize(sectorSize) }
        if let r = SDAParameters.exfat.first(where: { totalSectors >= $0.minSectors && totalSectors <= $0.maxSectors }) {
            return exfat(totalSectors: totalSectors, range: r)
        }
        if let r = SDAParameters.fat32.first(where: { totalSectors >= $0.minSectors && totalSectors <= $0.maxSectors }) {
            return fat32(totalSectors: totalSectors, range: r)
        }
        if totalSectors < SDAParameters.fat32[0].minSectors { throw FormatPlanError.legacyCardTooSmall(totalSectors) }
        throw FormatPlanError.outsideSDARanges(totalSectors)
    }

    /// Layout medido no oficial: partição em BU, FAT em BU/2 com tamanho BU/2, heap em BU.
    private static func exfat(totalSectors: UInt64, range r: SDARange) -> FormatPlan {
        let bu = UInt64(r.boundaryUnitSectors)
        let partSectors = totalSectors - bu
        let heap = bu
        let clusters = UInt32((partSectors - heap) / UInt64(r.sectorsPerCluster))
        return FormatPlan(totalSectors: totalSectors, fileSystem: .exfat, boundaryUnitSectors: r.boundaryUnitSectors,
                          sectorsPerCluster: r.sectorsPerCluster, partitionStartSector: bu, partitionSectorCount: partSectors,
                          partitionType: 0x07, fatOffset: UInt32(bu / 2), clusterHeapOffset: UInt32(heap),
                          clusterCount: clusters, reservedSectors: 0, fatLength: UInt32(bu / 2), numberOfFATs: 1)
    }

    /// FAT32: partição em BU; acha (reservados, setores/FAT) tais que reservados + 2·FAT é múltiplo de BU e a
    /// FAT é a mínima que cobre os clusters resultantes. Converge em 2–3 voltas (30 GiB → 1028/7678, igual ao oficial).
    private static func fat32(totalSectors: UInt64, range r: SDARange) -> FormatPlan {
        let bu = UInt64(r.boundaryUnitSectors)
        let spc = UInt64(r.sectorsPerCluster)
        let partSectors = totalSectors - bu
        func fatFor(clusters: UInt64) -> UInt64 { ((clusters + 2) * 4 + 511) / 512 }
        func reservedFor(fat: UInt64) -> UInt64 {
            var rsv = bu - (2 * fat) % bu
            if rsv == bu { rsv = 0 }
            while rsv < 32 { rsv += bu }   // FAT32 exige ≥ 32 reservados (boot, FSInfo, backup em 6)
            return rsv
        }
        var fat = fatFor(clusters: partSectors / spc)
        for _ in 0..<16 {
            let rsv = reservedFor(fat: fat)
            let clusters = (partSectors - rsv - 2 * fat) / spc
            let need = fatFor(clusters: clusters)
            if need == fat { break }
            fat = need
        }
        let rsv = reservedFor(fat: fat)
        let clusters = UInt32((partSectors - rsv - 2 * fat) / spc)
        return FormatPlan(totalSectors: totalSectors, fileSystem: .fat32, boundaryUnitSectors: r.boundaryUnitSectors,
                          sectorsPerCluster: r.sectorsPerCluster, partitionStartSector: bu, partitionSectorCount: partSectors,
                          partitionType: 0x0C, fatOffset: UInt32(rsv), clusterHeapOffset: UInt32(rsv + 2 * fat),
                          clusterCount: clusters, reservedSectors: UInt32(rsv), fatLength: UInt32(fat), numberOfFATs: 2)
    }
}
