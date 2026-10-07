import Foundation

/// MBR igual à do formatador oficial: área de boot zerada, assinatura de disco, UMA entrada, 55 AA.
public enum MBR {
    public static func bytes(for plan: FormatPlan, diskSignature: UInt32) -> [UInt8] {
        var m = [UInt8](repeating: 0, count: 512)
        put32(&m, 440, diskSignature)
        let e = 446
        m[e] = 0x00                                                  // não inicializável
        let start = chs(lba: plan.partitionStartSector)
        m[e+1] = start.0; m[e+2] = start.1; m[e+3] = start.2
        m[e+4] = plan.partitionType
        let end = chs(lba: plan.partitionStartSector + plan.partitionSectorCount - 1)
        m[e+5] = end.0; m[e+6] = end.1; m[e+7] = end.2
        put32(&m, e+8, UInt32(plan.partitionStartSector))
        put32(&m, e+12, UInt32(truncatingIfNeeded: plan.partitionSectorCount))
        m[510] = 0x55; m[511] = 0xAA
        return m
    }

    public static func randomSignature() -> UInt32 { UInt32.random(in: 1...UInt32.max) }

    /// CHS com geometria 255 cabeças × 63 setores. Acima de 1023 cilindros → FE FF FF (convenção).
    static func chs(lba: UInt64) -> (UInt8, UInt8, UInt8) {
        let spt: UInt64 = 63, heads: UInt64 = 255
        let c = lba / (spt * heads)
        guard c <= 1023 else { return (0xFE, 0xFF, 0xFF) }
        let h = (lba / spt) % heads
        let s = (lba % spt) + 1
        return (UInt8(h), UInt8(s | ((c >> 8) << 6)), UInt8(c & 0xFF))
    }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xFF); b[o+1] = UInt8((v >> 8) & 0xFF); b[o+2] = UInt8((v >> 16) & 0xFF); b[o+3] = UInt8(v >> 24)
    }
}
