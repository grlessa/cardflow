import Foundation

/// Confere o disco formatado contra o plano. Lista vazia = ok. Nunca "corrige": só reporta.
public enum PostFormatVerifier {
    public static func issues(device: BlockDevice, plan: FormatPlan) -> [String] {
        let info: BootInfo
        do { info = try BootSectorReader.read(device) } catch { return ["leitura: \(error)"] }
        var out: [String] = []
        if info.fileSystem != plan.fileSystem { out.append("sistema de arquivos \(info.fileSystem) ≠ \(plan.fileSystem)") }
        if info.partitionType != plan.partitionType { out.append("tipo de partição \(info.partitionType) ≠ \(plan.partitionType)") }
        if info.partitionStart != plan.partitionStartSector { out.append("partição em \(info.partitionStart) ≠ \(plan.partitionStartSector)") }
        if info.partitionSectors != plan.partitionSectorCount { out.append("tamanho da partição \(info.partitionSectors) ≠ \(plan.partitionSectorCount)") }
        if info.clusterBytes != plan.clusterBytes { out.append("cluster \(info.clusterBytes) ≠ \(plan.clusterBytes)") }
        let expectedDataStart = plan.partitionStartSector + UInt64(plan.clusterHeapOffset)
        if info.dataStartAbsolute != expectedDataStart || info.dataStartAbsolute % UInt64(plan.boundaryUnitSectors) != 0 {
            out.append("área de dados desalinhada (\(info.dataStartAbsolute) ≠ \(expectedDataStart))")
        }
        if info.fatLength != plan.fatLength { out.append("FAT \(info.fatLength) ≠ \(plan.fatLength)") }
        if plan.fileSystem == .fat32 && info.reservedSectors != plan.reservedSectors {
            out.append("reservados \(info.reservedSectors) ≠ \(plan.reservedSectors)")
        }
        return out
    }
}
