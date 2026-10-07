import Foundation

/// FAT32 usa o `newfs_msdos` do macOS (a prova de viabilidade mostrou layout igual ao oficial com -r).
public enum FAT32Format {
    public static let newfsPath = "/sbin/newfs_msdos"

    public static func newfsArguments(plan: FormatPlan, label: String, partitionRawDevice: String) -> [String] {
        var a = ["-F", "32", "-c", "\(plan.sectorsPerCluster)", "-r", "\(plan.reservedSectors)",
                 "-a", "\(plan.fatLength)", "-n", "2", "-O", "MSWIN4.1", "-h", "255", "-u", "63",
                 "-o", "\(plan.partitionStartSector)", "-S", "512"]
        let l = VolumeLabel.fat(label)
        if !l.isEmpty { a += ["-v", l] }
        return a + [partitionRawDevice]
    }

    /// Zera do setor 0 até o fim da área de metadados planejada, escreve a MBR e limpa GPT antigo no fim.
    public static func writePartitionTable(plan: FormatPlan, to device: BlockDevice, mbrSignature: UInt32) throws {
        let metaEnd = plan.partitionStartSector + UInt64(plan.clusterHeapOffset)
        try device.zero(sector: 0, count: metaEnd)
        try device.write(sector: 0, MBR.bytes(for: plan, diskSignature: mbrSignature))
        if device.sectorCount > 34 { try device.zero(sector: device.sectorCount - 34, count: 34) }
        try device.synchronize()
    }
}
