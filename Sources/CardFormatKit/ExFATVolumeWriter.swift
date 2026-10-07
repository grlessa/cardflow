import Foundation

/// Gera um volume exFAT VAZIO com o layout SDA (igual ao SD Card Formatter oficial, medido em imagens).
public struct ExFATVolumeWriter {
    public let plan: FormatPlan
    public let label: String
    public let volumeSerial: UInt32

    public init(plan: FormatPlan, label: String, volumeSerial: UInt32) {
        precondition(plan.fileSystem == .exfat)
        self.plan = plan; self.label = VolumeLabel.exfat(label); self.volumeSerial = volumeSerial
    }

    // Clusters fixos: bitmap a partir do 2, depois maiúsculas, depois raiz.
    var bitmapBytes: UInt64 { (UInt64(plan.clusterCount) + 7) / 8 }
    var bitmapClusters: UInt32 { UInt32((bitmapBytes + UInt64(plan.clusterBytes) - 1) / UInt64(plan.clusterBytes)) }
    var upcaseCluster: UInt32 { 2 + bitmapClusters }
    var rootCluster: UInt32 { upcaseCluster + 1 }

    /// 12 setores: boot, 8 estendidos, parâmetros OEM (flash), reservado, checksum.
    func bootRegion() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 12 * 512)
        // setor 0: boot sector
        r[0] = 0xEB; r[1] = 0x76; r[2] = 0x90
        for (i, ch) in "EXFAT   ".utf8.enumerated() { r[3 + i] = ch }
        put64(&r, 64, plan.partitionStartSector)
        put64(&r, 72, plan.partitionSectorCount)
        put32(&r, 80, plan.fatOffset)
        put32(&r, 84, plan.fatLength)
        put32(&r, 88, plan.clusterHeapOffset)
        put32(&r, 92, plan.clusterCount)
        put32(&r, 96, rootCluster)
        put32(&r, 100, volumeSerial)
        r[104] = 0x00; r[105] = 0x01                     // revisão 1.00
        r[108] = 9                                        // 512 bytes/setor
        r[109] = UInt8(plan.sectorsPerCluster.trailingZeroBitCount)
        r[110] = 1; r[111] = 0x80
        for i in 120..<510 { r[i] = 0xF4 }
        r[510] = 0x55; r[511] = 0xAA
        // setores 1–8: boot estendido (zeros + 00 00 55 AA)
        for s in 1...8 { r[s * 512 + 510] = 0x55; r[s * 512 + 511] = 0xAA }
        // setor 9: parâmetros de flash (GUID padrão + EraseBlockSize = BU/2 em bytes)
        let guid: [UInt8] = [0x46, 0x7E, 0x0C, 0x0A, 0x99, 0x33, 0x21, 0x40, 0x90, 0xC8, 0xFA, 0x6D, 0x38, 0x9C, 0x4B, 0xA2]
        for (i, b) in guid.enumerated() { r[9 * 512 + i] = b }
        put32(&r, 9 * 512 + 16, UInt32(plan.boundaryUnitSectors / 2) * 512)
        // setor 10 reservado (zeros); setor 11: checksum repetido
        let ck = ExFATChecksum.bootRegion(r)
        for i in stride(from: 11 * 512, to: 12 * 512, by: 4) { put32(&r, i, ck) }
        return r
    }

    /// FAT: entradas 0–1 + cadeias do bitmap (contíguo), maiúsculas e raiz. Só os setores com conteúdo.
    func fatFirstSectors() -> [UInt8] {
        let lastUsed = Int(rootCluster)
        let sectors = ((lastUsed + 1) * 4 + 511) / 512
        var f = [UInt8](repeating: 0, count: sectors * 512)
        put32(&f, 0, 0xFFFF_FFF8); put32(&f, 4, 0xFFFF_FFFF)
        let lastBitmap = 2 + Int(bitmapClusters) - 1
        for c in 2...lastBitmap { put32(&f, c * 4, c == lastBitmap ? 0xFFFF_FFFF : UInt32(c + 1)) }
        put32(&f, Int(upcaseCluster) * 4, 0xFFFF_FFFF)
        put32(&f, Int(rootCluster) * 4, 0xFFFF_FFFF)
        return f
    }

    /// Bitmap de alocação: marca os clusters do próprio bitmap, das maiúsculas e da raiz.
    func bitmap() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Int(bitmapClusters) * plan.clusterBytes)
        let used = Int(bitmapClusters) + 2
        for i in 0..<used { b[i / 8] |= UInt8(1 << (i % 8)) }
        return b
    }

    /// Raiz: rótulo (0x83, ou 0x03 quando vazio), bitmap (0x81), maiúsculas (0x82); resto zero.
    func rootDirectoryCluster() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: plan.clusterBytes)
        let units = Array(label.utf16)
        if units.isEmpty {
            r[0] = 0x03
        } else {
            r[0] = 0x83; r[1] = UInt8(units.count)
            for (i, u) in units.enumerated() { r[2 + i * 2] = UInt8(u & 0xFF); r[3 + i * 2] = UInt8(u >> 8) }
        }
        r[32] = 0x81
        put32(&r, 32 + 20, 2)
        put64(&r, 32 + 24, bitmapBytes)
        r[64] = 0x82
        put32(&r, 64 + 4, ExFATChecksum.table(ExFATUpcaseTable.bytes))
        put32(&r, 64 + 20, upcaseCluster)
        put64(&r, 64 + 24, UInt64(ExFATUpcaseTable.bytes.count))
        return r
    }

    func clusterSector(_ c: UInt32) -> UInt64 {
        plan.partitionStartSector + UInt64(plan.clusterHeapOffset) + UInt64(c - 2) * UInt64(plan.sectorsPerCluster)
    }

    /// Escreve no DISCO INTEIRO (device = /dev/rdiskN ou arquivo-imagem). Formatação rápida: zera só a
    /// área de metadados (do setor 0 até o heap) e os clusters usados; o resto do heap fica como estava.
    public func write(to device: BlockDevice, mbrSignature: UInt32) throws {
        let p = plan
        let heapAbs = p.partitionStartSector + UInt64(p.clusterHeapOffset)
        try device.zero(sector: 0, count: heapAbs)
        try device.write(sector: 0, MBR.bytes(for: p, diskSignature: mbrSignature))
        let boot = bootRegion()
        try device.write(sector: p.partitionStartSector, boot)
        try device.write(sector: p.partitionStartSector + 12, boot)
        try device.write(sector: p.partitionStartSector + UInt64(p.fatOffset), fatFirstSectors())
        try device.write(sector: clusterSector(2), bitmap())
        var up = [UInt8](repeating: 0, count: p.clusterBytes)
        up.replaceSubrange(0..<ExFATUpcaseTable.bytes.count, with: ExFATUpcaseTable.bytes)
        try device.write(sector: clusterSector(upcaseCluster), up)
        try device.write(sector: clusterSector(rootCluster), rootDirectoryCluster())
        // resto de GPT antigo no fim do disco (cabeçalho de backup) some
        let tail: UInt64 = 34
        if device.sectorCount > tail { try device.zero(sector: device.sectorCount - tail, count: tail) }
        try device.synchronize()
    }

    func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for k in 0..<4 { b[o + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) }
    }
    func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        for k in 0..<8 { b[o + k] = UInt8((v >> (8 * UInt64(k))) & 0xFF) }
    }
}
