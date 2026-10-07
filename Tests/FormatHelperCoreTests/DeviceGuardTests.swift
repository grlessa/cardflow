import Testing
@testable import FormatHelperCore
import CardFormatXPC

@Suite struct DeviceGuardTests {
    var card: DiskDescription {
        DiskDescription(bsdName: "disk4", isWhole: true, isRemovable: true, isEjectable: true, isInternal: false,
                        isWritable: true, totalBytes: 64_088_965_120, blockSize: 512, containsBootVolume: false,
                        partitionFileSystems: ["exfat"], volumeUUIDs: ["UUID-A"])
    }
    var req: FormatRequest { FormatRequest(bsdName: "disk4", expectedTotalBytes: 64_088_965_120, expectedVolumeUUID: "UUID-A", label: "X") }

    @Test func cartaoNormalPassa() throws {
        let plan = try DeviceGuard.validate(card, request: req).get()
        #expect(plan.fileSystem == .exfat)
    }

    @Test func recusas() {
        func rej(_ edit: (inout DiskDescription) -> Void, _ r: FormatRequest? = nil) -> GuardRejection? {
            var d = card; edit(&d)
            if case .failure(let e) = DeviceGuard.validate(d, request: r ?? req) { return e }
            return nil
        }
        #expect(rej { $0.isWhole = false } == .notWhole)
        #expect(rej { $0.isRemovable = false; $0.isEjectable = false } == .notRemovable)
        #expect(rej { $0.isInternal = true; $0.isRemovable = false } == .internalDisk)   // SSD interno do Mac
        #expect(rej { $0.isWritable = false } == .readOnly)
        #expect(rej { $0.containsBootVolume = true } == .bootDisk)
        #expect(rej { $0.partitionFileSystems = ["apfs"] } == .unsupportedFileSystem("apfs"))
        #expect(rej { $0.partitionFileSystems = ["hfs"] } == .unsupportedFileSystem("hfs"))
        #expect(rej { $0.totalBytes = 1 } == .sizeMismatch)
        #expect(rej { $0.volumeUUIDs = ["UUID-B"] } == .cardChanged)
        #expect(rej { $0.blockSize = 4096 } == .sectorSize(4096))
        #expect(rej({ $0.totalBytes = 3_000_000_000_000 },
                    FormatRequest(bsdName: "disk4", expectedTotalBytes: 3_000_000_000_000, expectedVolumeUUID: "UUID-A", label: "")) == .tooLargeForMBR)
    }

    @Test func discoSemVolumeLegivelPassaSeTamanhoBate() throws {
        var d = card; d.partitionFileSystems = []; d.volumeUUIDs = []
        let r = FormatRequest(bsdName: "disk4", expectedTotalBytes: 64_088_965_120, expectedVolumeUUID: nil, label: "")
        _ = try DeviceGuard.validate(d, request: r).get()
    }

    /// Leitor de SD embutido do MacBook: o DISPOSITIVO é interno, mas a MÍDIA é removível. Tem que passar.
    @Test func leitorDeSDEmbutidoDoMacPassa() throws {
        var d = card; d.isInternal = true; d.isRemovable = true
        _ = try DeviceGuard.validate(d, request: req).get()
    }
}
