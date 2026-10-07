import Testing
import Foundation
@testable import CardFormatKit

@Suite struct ExFATVolumeTests {
    let total: UInt64 = 134_217_728   // 64 GiB, referência oficial

    func writer(_ g: [UInt8]) throws -> ExFATVolumeWriter {
        ExFATVolumeWriter(plan: try FormatPlan.make(totalSectors: total, sectorSize: 512),
                          label: "TESTE", volumeSerial: Fixture.u32(g, 100))
    }

    @Test func tabelaDeMaiusculasEmbutidaEhAPadrao() {
        #expect(ExFATUpcaseTable.bytes == Fixture.bytes("exfat_upcase_table.bin"))
    }

    @Test func fatERaizIguaisAoOficial() throws {
        let w = try writer(Fixture.bytes("exfat64g_boot_region.bin"))
        #expect(Array(w.fatFirstSectors().prefix(512)) == Fixture.bytes("exfat64g_fat_sector0.bin"))
        #expect(Array(w.rootDirectoryCluster().prefix(512)) == Fixture.bytes("exfat64g_root_sector0.bin"))
        #expect(w.bitmapClusters == 1 && w.upcaseCluster == 3 && w.rootCluster == 4)
        #expect(Array(w.bitmap().prefix(2)) == [0x07, 0x00])
    }

    @Test func escreveNoDiscoInteiroComLayoutOficial() throws {
        let g = Fixture.bytes("exfat64g_boot_region.bin")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileBlockDevice.createSparse(at: path, sectors: total)
        try dev.write(sector: 0, [UInt8](repeating: 0xEE, count: 512 * 64))   // lixo antigo no começo
        let w = try writer(g)
        try w.write(to: dev, mbrSignature: Fixture.u32(Fixture.bytes("exfat64g_mbr.bin"), 440))
        #expect(try dev.read(sector: 0, count: 1) == Fixture.bytes("exfat64g_mbr.bin"))
        #expect(try dev.read(sector: 1, count: 63) == [UInt8](repeating: 0, count: 63 * 512))
        #expect(try dev.read(sector: 32_768, count: 24) == g)
        #expect(try dev.read(sector: 32_768 + 16_384, count: 1) == Fixture.bytes("exfat64g_fat_sector0.bin"))
        let heap: UInt64 = 32_768 + 32_768
        let up = try dev.read(sector: heap + 256, count: 12)
        #expect(Array(up.prefix(5836)) == Fixture.bytes("exfat_upcase_table.bin"))
        #expect(try dev.read(sector: heap + 512, count: 1) == Fixture.bytes("exfat64g_root_sector0.bin"))
    }

    @Test func semRotuloUsaEntradaVazia() throws {
        let w = ExFATVolumeWriter(plan: try FormatPlan.make(totalSectors: total, sectorSize: 512), label: "", volumeSerial: 1)
        let root = w.rootDirectoryCluster()
        #expect(root[0] == 0x03 && root[1] == 0)
        #expect(root[32] == 0x81 && root[64] == 0x82)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARDFLOW_DISK_IMAGE_TESTS"] == "1"))
    func fsckAprovaEMacOSMonta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("card.img").path
        let dev = try FileBlockDevice.createSparse(at: img, sectors: total)
        try ExFATVolumeWriter(plan: try FormatPlan.make(totalSectors: total, sectorSize: 512), label: "CARDFLOW",
                              volumeSerial: 0x1234_5678).write(to: dev, mbrSignature: 0xCAFE_F00D)
        dev.close()
        let attach = try DiskImageTool.attach(img)
        defer { DiskImageTool.detach(attach.wholeDisk) }
        let fsck = try DiskImageTool.run("/sbin/fsck_exfat", ["-n", "/dev/r\(attach.wholeDisk)s1"])
        #expect(fsck.status == 0, "\(fsck.out)")
        let mount = try DiskImageTool.mount("\(attach.wholeDisk)s1")
        #expect(FileManager.default.fileExists(atPath: mount))
        try Data("ok".utf8).write(to: URL(fileURLWithPath: mount).appendingPathComponent("t.txt"))
    }
}
