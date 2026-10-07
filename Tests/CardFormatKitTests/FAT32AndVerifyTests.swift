import Testing
import Foundation
@testable import CardFormatKit

@Suite struct FAT32AndVerifyTests {
    @Test func argumentosDoNewfs() throws {
        let p = try FormatPlan.make(totalSectors: 62_914_560, sectorSize: 512)
        #expect(FAT32Format.newfsArguments(plan: p, label: "Cartão a", partitionRawDevice: "/dev/rdisk9s1") ==
            ["-F", "32", "-c", "64", "-r", "1028", "-a", "7678", "-n", "2", "-O", "MSWIN4.1",
             "-h", "255", "-u", "63", "-o", "8192", "-S", "512", "-v", "CART_O A", "/dev/rdisk9s1"])
        #expect(!FAT32Format.newfsArguments(plan: p, label: "", partitionRawDevice: "/dev/rdisk9s1").contains("-v"))
    }

    @Test func leBootFAT32DaReferencia() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileBlockDevice.createSparse(at: path, sectors: 62_914_560)
        try dev.write(sector: 0, Fixture.bytes("fat32_30g_mbr.bin"))
        try dev.write(sector: 8_192, Fixture.bytes("fat32_30g_boot_sectors.bin"))
        let info = try BootSectorReader.read(dev)
        #expect(info == BootInfo(fileSystem: .fat32, partitionStart: 8_192, dataStartAbsolute: 24_576,
                                 clusterBytes: 32_768, fatLength: 7_678, reservedSectors: 1_028))
        #expect(PostFormatVerifier.issues(device: dev, plan: try FormatPlan.make(totalSectors: 62_914_560, sectorSize: 512)).isEmpty)
    }

    @Test func conferenciaPegaExFATDesalinhado() throws {
        let total: UInt64 = 134_217_728
        let plan = try FormatPlan.make(totalSectors: total, sectorSize: 512)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileBlockDevice.createSparse(at: path, sectors: total)
        try ExFATVolumeWriter(plan: plan, label: "X", volumeSerial: 7).write(to: dev, mbrSignature: 1)
        #expect(PostFormatVerifier.issues(device: dev, plan: plan).isEmpty)
        var boot = try dev.read(sector: 32_768, count: 1)
        boot[88] = 0x00; boot[89] = 0x18                     // heap em 6144 (o layout do newfs_exfat)
        try dev.write(sector: 32_768, boot)
        #expect(!PostFormatVerifier.issues(device: dev, plan: plan).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARDFLOW_DISK_IMAGE_TESTS"] == "1"))
    func newfsMsdosGeraOLayoutPlanejado() throws {
        let total: UInt64 = 62_914_560
        let plan = try FormatPlan.make(totalSectors: total, sectorSize: 512)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("card.img").path
        let dev = try FileBlockDevice.createSparse(at: img, sectors: total)
        try FAT32Format.writePartitionTable(plan: plan, to: dev, mbrSignature: 42)
        dev.close()
        let a = try DiskImageTool.attach(img)
        defer { DiskImageTool.detach(a.wholeDisk) }
        let r = try DiskImageTool.run(FAT32Format.newfsPath,
                                      FAT32Format.newfsArguments(plan: plan, label: "TESTE", partitionRawDevice: "/dev/r\(a.wholeDisk)s1"))
        #expect(r.status == 0, "\(r.out)")
        let whole = try FileBlockDevice(path: "/dev/r\(a.wholeDisk)", sectorCount: total)
        #expect(PostFormatVerifier.issues(device: whole, plan: plan).isEmpty)
        whole.close()   // o fsck recusa disco aberto pra escrita (igual ao helper real, que fecha antes)
        let fsck = try DiskImageTool.run("/sbin/fsck_msdos", ["-n", "/dev/r\(a.wholeDisk)s1"])
        #expect(fsck.status == 0, "\(fsck.out)")
    }
}
