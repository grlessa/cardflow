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
        var d = card; d.partitionFileSystems = []; d.volumeUUIDs = []; d.sliceCount = 0
        let r = FormatRequest(bsdName: "disk4", expectedTotalBytes: 64_088_965_120, expectedVolumeUUID: nil, label: "")
        _ = try DeviceGuard.validate(d, request: r).get()
    }

    /// Leitor de SD embutido do MacBook: o DISPOSITIVO é interno, mas a MÍDIA é removível. Tem que passar.
    @Test func leitorDeSDEmbutidoDoMacPassa() throws {
        var d = card; d.isInternal = true; d.isRemovable = true
        _ = try DeviceGuard.validate(d, request: req).get()
    }

    @Test func recusaMultiParticaoSynthesizedAPFSFatiaDesconhecidaENomeInvalido() {
        var multi = card; multi.sliceCount = 2; multi.partitionFileSystems = ["exfat", "exfat"]
        if case .failure(.multiplePartitions(2)) = DeviceGuard.validate(multi, request: req) {} else {
            Issue.record("devia recusar multi-partição")
        }

        var synth = card; synth.isSynthesizedAPFS = true; synth.partitionFileSystems = []; synth.sliceCount = 0
        if case .failure(.unsupportedFileSystem("apfs")) = DeviceGuard.validate(synth, request: req) {} else {
            Issue.record("devia recusar contêiner APFS sintetizado")
        }

        // Fatia presente sem VolumeKind conhecido (ex.: partição GPT APFS/EFI desmontada)
        var unk = card; unk.sliceCount = 1; unk.partitionFileSystems = []
        if case .failure(.unsupportedFileSystem("unknown")) = DeviceGuard.validate(unk, request: req) {} else {
            Issue.record("devia recusar fatia sem sistema conhecido")
        }

        for bad in ["/dev/disk4", "rdisk4", "disk4s1", "disk", ""] {
            let r = FormatRequest(bsdName: bad, expectedTotalBytes: card.totalBytes, expectedVolumeUUID: "UUID-A", label: "X")
            var d = card; d.bsdName = bad
            if case .failure(.notWhole) = DeviceGuard.validate(d, request: r) {} else {
                Issue.record("devia recusar bsdName inválido \(bad)")
            }
        }
    }
}
