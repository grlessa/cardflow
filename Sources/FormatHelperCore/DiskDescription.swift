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
    public init(bsdName: String, isWhole: Bool, isRemovable: Bool, isEjectable: Bool, isInternal: Bool, isWritable: Bool,
                totalBytes: UInt64, blockSize: Int, containsBootVolume: Bool, partitionFileSystems: [String], volumeUUIDs: [String]) {
        self.bsdName = bsdName; self.isWhole = isWhole; self.isRemovable = isRemovable; self.isEjectable = isEjectable
        self.isInternal = isInternal; self.isWritable = isWritable; self.totalBytes = totalBytes; self.blockSize = blockSize
        self.containsBootVolume = containsBootVolume; self.partitionFileSystems = partitionFileSystems; self.volumeUUIDs = volumeUUIDs
    }
}

public enum GuardRejection: Error, Equatable, Sendable {
    case notWhole, notRemovable, internalDisk, readOnly, bootDisk, unsupportedFileSystem(String)
    case sizeMismatch, cardChanged, sectorSize(Int), tooLargeForMBR, plan(FormatPlanError)
}

/// O helper roda como root: NÃO confia no app. Toda condição é checada aqui de novo, sobre o disco real.
public enum DeviceGuard {
    static let cameraFileSystems: Set<String> = ["msdos", "exfat"]
    static let maxMBRSectors: UInt64 = 4_294_705_152   // acima disso o oficial usa GPT: fora de escopo

    public static func validate(_ d: DiskDescription, request: FormatRequest) -> Result<FormatPlan, GuardRejection> {
        guard d.isWhole, d.bsdName == request.bsdName else { return .failure(.notWhole) }
        guard d.isRemovable || d.isEjectable else { return .failure(.notRemovable) }
        // Interno E fixo (SSD do Mac) nunca. Interno com mídia removível é o leitor de SD embutido do MacBook.
        guard !d.isInternal || d.isRemovable else { return .failure(.internalDisk) }
        guard d.isWritable else { return .failure(.readOnly) }
        guard !d.containsBootVolume else { return .failure(.bootDisk) }
        if let bad = d.partitionFileSystems.first(where: { !cameraFileSystems.contains($0.lowercased()) }) {
            return .failure(.unsupportedFileSystem(bad))
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
