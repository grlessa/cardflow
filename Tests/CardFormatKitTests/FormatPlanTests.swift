import Testing
@testable import CardFormatKit

@Suite struct FormatPlanTests {
    // Valores medidos no formatador oficial (pesquisa §8).
    @Test func exfat64GiBIgualAoOficial() throws {
        let p = try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512)
        #expect(p.fileSystem == .exfat)
        #expect(p.boundaryUnitSectors == 32_768)
        #expect(p.sectorsPerCluster == 256)
        #expect(p.partitionStartSector == 32_768)
        #expect(p.partitionSectorCount == 134_184_960)
        #expect(p.partitionType == 0x07)
        #expect(p.fatOffset == 16_384 && p.fatLength == 16_384)
        #expect(p.clusterHeapOffset == 32_768)
        #expect(p.clusterCount == 524_032)
        #expect(p.clusterBytes == 131_072)
    }

    @Test func exfat256GiBIgualAoOficial() throws {
        let p = try FormatPlan.make(totalSectors: 536_870_912, sectorSize: 512)
        #expect(p.boundaryUnitSectors == 65_536 && p.sectorsPerCluster == 512)
        #expect(p.partitionStartSector == 65_536)
        #expect(p.fatOffset == 32_768 && p.fatLength == 32_768 && p.clusterHeapOffset == 65_536)
        #expect(p.clusterCount == 1_048_320)
    }

    @Test func fat32De30GiBIgualAoOficial() throws {
        let p = try FormatPlan.make(totalSectors: 62_914_560, sectorSize: 512)
        #expect(p.fileSystem == .fat32)
        #expect(p.partitionStartSector == 8_192 && p.partitionSectorCount == 62_906_368)
        #expect(p.partitionType == 0x0C)
        #expect(p.sectorsPerCluster == 64)
        #expect(p.reservedSectors == 1_028 && p.fatLength == 7_678 && p.numberOfFATs == 2)
        #expect((p.partitionStartSector + UInt64(p.reservedSectors) + 2 * UInt64(p.fatLength)) % 8_192 == 0)
    }

    @Test func cartoesReaisDeMercado() throws {
        #expect(try FormatPlan.make(totalSectors: 62_333_952, sectorSize: 512).fileSystem == .fat32)
        let p64 = try FormatPlan.make(totalSectors: 122_142_720, sectorSize: 512)
        #expect(p64.fileSystem == .exfat && p64.sectorsPerCluster == 256)
        #expect(try FormatPlan.make(totalSectors: 244_285_440, sectorSize: 512).sectorsPerCluster == 256)
        let p1t = try FormatPlan.make(totalSectors: 1_953_525_168, sectorSize: 512)
        #expect(p1t.sectorsPerCluster == 1_024 && p1t.boundaryUnitSectors == 131_072)
    }

    @Test func alinhamentosSempreValem() throws {
        for total: UInt64 in [8_192_001, 40_000_000, 66_945_024, 67_108_864, 300_000_000, 4_294_705_152, 5_000_000_000] {
            let p = try FormatPlan.make(totalSectors: total, sectorSize: 512)
            let bu = UInt64(p.boundaryUnitSectors)
            #expect(p.partitionStartSector % bu == 0, "partição desalinhada em \(total)")
            let dataStart = p.fileSystem == .exfat
                ? p.partitionStartSector + UInt64(p.clusterHeapOffset)
                : p.partitionStartSector + UInt64(p.reservedSectors) + UInt64(p.numberOfFATs) * UInt64(p.fatLength)
            #expect(dataStart % bu == 0, "área de dados desalinhada em \(total)")
            #expect(p.partitionStartSector + p.partitionSectorCount == total)
            if p.fileSystem == .exfat {
                #expect(UInt64(p.clusterCount + 2) * 4 <= UInt64(p.fatLength) * 512, "FAT não cabe em \(total)")
            }
        }
    }

    @Test func recusas() {
        #expect(throws: FormatPlanError.unsupportedSectorSize(4096)) { try FormatPlan.make(totalSectors: 100_000_000, sectorSize: 4096) }
        #expect(throws: FormatPlanError.legacyCardTooSmall(3_900_000)) { try FormatPlan.make(totalSectors: 3_900_000, sectorSize: 512) }
        #expect(throws: FormatPlanError.outsideSDARanges(67_000_000)) { try FormatPlan.make(totalSectors: 67_000_000, sectorSize: 512) }
        #expect(throws: FormatPlanError.outsideSDARanges(4_294_800_000)) { try FormatPlan.make(totalSectors: 4_294_800_000, sectorSize: 512) }
    }
}
