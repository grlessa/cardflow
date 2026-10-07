import Testing
@testable import CardFormatKit

@Suite struct ExFATBootTests {
    @Test(arguments: [("exfat64g_boot_region.bin", UInt64(134_217_728)),
                      ("exfat256g_boot_region.bin", UInt64(536_870_912))])
    func regiaoDeBootIgualAoOficial(fixture: String, total: UInt64) throws {
        let golden = Fixture.bytes(fixture)                 // 24 setores: principal + backup
        let serial = Fixture.u32(golden, 100)               // serial é aleatório: usamos o da referência
        let w = ExFATVolumeWriter(plan: try FormatPlan.make(totalSectors: total, sectorSize: 512),
                                  label: "TESTE", volumeSerial: serial)
        let mine = w.bootRegion()
        #expect(mine.count == 12 * 512)
        #expect(mine == Array(golden[0..<6144]))
        #expect(mine == Array(golden[6144..<12288]))
    }

    @Test func checksumDaTabelaDeMaiusculasPadrao() {
        #expect(ExFATChecksum.table(Fixture.bytes("exfat_upcase_table.bin")) == 0xE619_D30D)
    }
}
