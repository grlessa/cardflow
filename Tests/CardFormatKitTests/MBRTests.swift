import Testing
@testable import CardFormatKit

@Suite struct MBRTests {
    @Test(arguments: [("exfat64g_mbr.bin", UInt64(134_217_728)),
                      ("exfat256g_mbr.bin", UInt64(536_870_912)),
                      ("fat32_30g_mbr.bin", UInt64(62_914_560))])
    func igualAoOficialByteAByte(fixture: String, total: UInt64) throws {
        let golden = Fixture.bytes(fixture)
        let plan = try FormatPlan.make(totalSectors: total, sectorSize: 512)
        let mine = MBR.bytes(for: plan, diskSignature: Fixture.u32(golden, 440))
        #expect(mine == golden)
    }

    @Test func rotuloExFAT() {
        #expect(VolumeLabel.exfat("CARTAO_A") == "CARTAO_A")
        #expect(VolumeLabel.exfat("Um nome comprido demais") == "Um nome com")
        #expect(VolumeLabel.exfat("a:b*c?") == "abc")
        #expect(VolumeLabel.exfat("   ") == "")
    }

    @Test func rotuloFAT() {
        #expect(VolumeLabel.fat("Cartão a") == "CART_O A")
        #expect(VolumeLabel.fat("EOS_DIGITAL") == "EOS_DIGITAL")
        #expect(VolumeLabel.fat("muito comprido aqui") == "MUITO COMPR")
        #expect(VolumeLabel.fat("a.b+c") == "ABC")
    }
}
