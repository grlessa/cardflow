import Foundation

/// Confere o disco formatado contra o plano. Lista vazia = ok. Nunca "corrige": só reporta.
public enum PostFormatVerifier {
    public static func issues(device: BlockDevice, plan: FormatPlan) -> [String] {
        let info: BootInfo
        do { info = try BootSectorReader.read(device) } catch { return ["leitura: \(error)"] }
        var out: [String] = []
        if info.fileSystem != plan.fileSystem { out.append("sistema de arquivos \(info.fileSystem) ≠ \(plan.fileSystem)") }
        if info.partitionStart != plan.partitionStartSector { out.append("partição em \(info.partitionStart) ≠ \(plan.partitionStartSector)") }
        if info.clusterBytes != plan.clusterBytes { out.append("cluster \(info.clusterBytes) ≠ \(plan.clusterBytes)") }
        if info.dataStartAbsolute % UInt64(plan.boundaryUnitSectors) != 0 { out.append("área de dados desalinhada (\(info.dataStartAbsolute))") }
        if info.fatLength != plan.fatLength { out.append("FAT \(info.fatLength) ≠ \(plan.fatLength)") }
        return out
    }
}
