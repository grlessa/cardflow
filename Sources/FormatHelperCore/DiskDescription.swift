import Foundation
import CardFormatKit
import CardFormatXPC

public struct DiskDescription: Equatable, Sendable {
    public var bsdName: String
    public var isWhole: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isWritable: Bool
    public var totalBytes: UInt64
    public var blockSize: Int
    public var containsBootVolume: Bool
    public var partitionFileSystems: [String]
    public var volumeUUIDs: [String]
    public var sliceCount: Int
    public var isSynthesizedAPFS: Bool
    public init(bsdName: String, isWhole: Bool, isRemovable: Bool, isEjectable: Bool, isInternal: Bool, isWritable: Bool,
                totalBytes: UInt64, blockSize: Int, containsBootVolume: Bool, partitionFileSystems: [String], volumeUUIDs: [String],
                sliceCount: Int? = nil, isSynthesizedAPFS: Bool = false) {
        self.bsdName = bsdName; self.isWhole = isWhole; self.isRemovable = isRemovable; self.isEjectable = isEjectable
        self.isInternal = isInternal; self.isWritable = isWritable; self.totalBytes = totalBytes; self.blockSize = blockSize
        self.containsBootVolume = containsBootVolume; self.partitionFileSystems = partitionFileSystems; self.volumeUUIDs = volumeUUIDs
        self.sliceCount = sliceCount ?? partitionFileSystems.count
        self.isSynthesizedAPFS = isSynthesizedAPFS
    }
}

public enum GuardRejection: Error, Equatable, Sendable {
    case notWhole, notRemovable, internalDisk, readOnly, bootDisk, unsupportedFileSystem(String), multiplePartitions(Int)
    case sizeMismatch, cardChanged, sectorSize(Int), tooLargeForMBR, plan(FormatPlanError)
}

/// O helper roda como root: NÃO confia no app. Toda condição é checada aqui de novo, sobre o disco real.
public enum DeviceGuard {
    static let cameraFileSystems: Set<String> = ["msdos", "exfat"]
    static let maxMBRSectors: UInt64 = 4_294_705_152   // acima disso o oficial usa GPT: fora de escopo

    /// Nome BSD canônico de disco inteiro: estritamente "diskN" (sem barra, sem "r", sem fatia "sM").
    public static func isValidWholeDiskBSD(_ bsd: String) -> Bool {
        guard bsd.hasPrefix("disk"), bsd.count > 4 else { return false }
        return bsd.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func validate(_ d: DiskDescription, request: FormatRequest) -> Result<FormatPlan, GuardRejection> {
        guard isValidWholeDiskBSD(request.bsdName), isValidWholeDiskBSD(d.bsdName),
              d.isWhole, d.bsdName == request.bsdName else { return .failure(.notWhole) }
        guard !d.isSynthesizedAPFS else { return .failure(.unsupportedFileSystem("apfs")) }
        guard d.isRemovable || d.isEjectable else { return .failure(.notRemovable) }
        // Interno E fixo (SSD do Mac) nunca. Interno com mídia removível é o leitor de SD embutido do MacBook.
        guard !d.isInternal || d.isRemovable else { return .failure(.internalDisk) }
        guard d.isWritable else { return .failure(.readOnly) }
        guard !d.containsBootVolume else { return .failure(.bootDisk) }
        // Cartão de câmera padrão tem no máximo uma partição (ou disco cru sem fatias). Multi-partição
        // pode conter EFI, APFS ou uma segunda partição de dados que não foi conferida pelo CardWipeCheck.
        guard d.sliceCount <= 1 else { return .failure(.multiplePartitions(d.sliceCount)) }
        if let bad = d.partitionFileSystems.first(where: { !cameraFileSystems.contains($0.lowercased()) }) {
            return .failure(.unsupportedFileSystem(bad))
        }
        // Allowlist estrita: se existe uma fatia no disco, ela TEM que ser identificada como msdos/exfat.
        if d.sliceCount > 0 && d.partitionFileSystems.count < d.sliceCount {
            return .failure(.unsupportedFileSystem("unknown"))
        }
        guard d.totalBytes == request.expectedTotalBytes else { return .failure(.sizeMismatch) }
        if let expected = request.expectedVolumeUUID, !d.volumeUUIDs.contains(expected) { return .failure(.cardChanged) }
        guard d.blockSize == 512 else { return .failure(.sectorSize(d.blockSize)) }
        let sectors = d.totalBytes / 512
        guard sectors <= maxMBRSectors else { return .failure(.tooLargeForMBR) }
        do { return .success(try FormatPlan.make(totalSectors: sectors, sectorSize: 512)) }
        catch let e as FormatPlanError { return .failure(.plan(e)) }
        catch { return .failure(.plan(.outsideSDARanges(sectors))) }
    }
}
