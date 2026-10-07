/// Faixas da SD Association extraídas do SD Card Formatter 5.0.3 (tabelas em 0x10017d430 e 0x1000fe850 do
/// `format_sd` arm64). Setores de 512 bytes.
struct SDARange: Equatable, Sendable {
    let minSectors: UInt64
    let maxSectors: UInt64
    let boundaryUnitSectors: UInt32
    let sectorsPerCluster: UInt32
}

enum SDAParameters {
    /// SDHC (FAT32). Linhas 14 e 15 da tabela FAT oficial (as únicas com is_FAT32 = 1).
    static let fat32: [SDARange] = [
        .init(minSectors: 4_211_713, maxSectors: 8_192_000, boundaryUnitSectors: 8_192, sectorsPerCluster: 64),
        .init(minSectors: 8_192_001, maxSectors: 66_945_024, boundaryUnitSectors: 8_192, sectorsPerCluster: 64),
    ]
    /// SDXC/SDUC (exFAT). Linhas válidas da tabela exFAT oficial (0 e 4 são inválidas).
    static let exfat: [SDARange] = [
        .init(minSectors: 67_108_864, maxSectors: 268_173_312, boundaryUnitSectors: 32_768, sectorsPerCluster: 256),
        .init(minSectors: 268_173_313, maxSectors: 1_073_479_680, boundaryUnitSectors: 65_536, sectorsPerCluster: 512),
        .init(minSectors: 1_073_479_681, maxSectors: 4_294_705_152, boundaryUnitSectors: 131_072, sectorsPerCluster: 1_024),
        .init(minSectors: 4_294_968_320, maxSectors: 8_589_934_592, boundaryUnitSectors: 262_144, sectorsPerCluster: 2_048),
        .init(minSectors: 8_589_934_593, maxSectors: 17_179_869_184, boundaryUnitSectors: 262_144, sectorsPerCluster: 4_096),
        .init(minSectors: 17_179_869_185, maxSectors: 34_359_738_368, boundaryUnitSectors: 524_288, sectorsPerCluster: 8_192),
        .init(minSectors: 34_359_738_369, maxSectors: 68_719_476_736, boundaryUnitSectors: 524_288, sectorsPerCluster: 16_384),
        .init(minSectors: 68_719_476_737, maxSectors: 137_438_953_472, boundaryUnitSectors: 1_048_576, sectorsPerCluster: 32_768),
        .init(minSectors: 137_438_953_473, maxSectors: 274_877_906_944, boundaryUnitSectors: 1_048_576, sectorsPerCluster: 65_536),
    ]
}
