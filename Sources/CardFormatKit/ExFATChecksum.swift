enum ExFATChecksum {
    /// Checksum da região de boot: setores 0–10, pulando VolumeFlags (106, 107) e PercentInUse (112).
    static func bootRegion(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0
        for i in 0..<(11 * 512) where i != 106 && i != 107 && i != 112 {
            c = ((c << 31) | (c >> 1)) &+ UInt32(b[i])
        }
        return c
    }
    /// Checksum de tabela (usado na tabela de maiúsculas).
    static func table(_ b: [UInt8]) -> UInt32 {
        var c: UInt32 = 0
        for x in b { c = ((c << 31) | (c >> 1)) &+ UInt32(x) }
        return c
    }
}
