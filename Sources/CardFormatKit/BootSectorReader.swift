import Foundation

public struct BootInfo: Equatable, Sendable {
    public let fileSystem: FileSystemKind
    public let partitionStart: UInt64
    public let dataStartAbsolute: UInt64
    public let clusterBytes: Int
    public let fatLength: UInt32
    public let reservedSectors: UInt32
}

public struct BootReadError: Error, Equatable { public let reason: String }

public enum BootSectorReader {
    public static func read(_ device: BlockDevice) throws -> BootInfo {
        let mbr = try device.read(sector: 0, count: 1)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else { throw BootReadError(reason: "MBR sem assinatura") }
        let start = UInt64(u32(mbr, 454))
        let b = try device.read(sector: start, count: 1)
        guard b[510] == 0x55, b[511] == 0xAA else { throw BootReadError(reason: "setor de boot sem assinatura") }
        if Array(b[3..<11]) == Array("EXFAT   ".utf8) {
            let heap = UInt64(u32(b, 88))
            return BootInfo(fileSystem: .exfat, partitionStart: start, dataStartAbsolute: start + heap,
                            clusterBytes: 512 << Int(b[109]), fatLength: u32(b, 84), reservedSectors: 0)
        }
        let spc = Int(b[13]), rsvd = UInt32(b[14]) | UInt32(b[15]) << 8, nf = UInt64(b[16]), fat = u32(b, 36)
        guard fat > 0, Array(b[82..<90]) == Array("FAT32   ".utf8) else { throw BootReadError(reason: "não é FAT32 nem exFAT") }
        return BootInfo(fileSystem: .fat32, partitionStart: start,
                        dataStartAbsolute: start + UInt64(rsvd) + nf * UInt64(fat),
                        clusterBytes: spc * 512, fatLength: fat, reservedSectors: rsvd)
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
    }
}
