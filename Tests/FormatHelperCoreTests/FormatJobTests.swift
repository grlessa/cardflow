import Testing
import Foundation
@testable import FormatHelperCore
import CardFormatKit
import CardFormatXPC

final class FakeSystem: DiskSystem {
    var desc: DiskDescription
    let imagePath: String
    var calls: [String] = []
    var unmountFails = false
    var fsckStatus: Int32 = 0
    var openRawFails = false
    init(desc: DiskDescription, imagePath: String) { self.desc = desc; self.imagePath = imagePath }
    func describe(bsdName: String) throws -> DiskDescription { calls.append("describe"); return desc }
    func unmountWhole(bsdName: String) throws { calls.append("unmountWhole"); if unmountFails { throw NSError(domain: "x", code: 16) } }
    func suppressAutomount(bsdName: String) { calls.append("suppress") }
    func restoreAutomount() { calls.append("restore") }
    func remountWhole(bsdName: String) { calls.append("remountWhole") }
    func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice {
        calls.append("openRaw")
        if openRawFails { throw BlockDeviceError(operation: "open /dev/r\(bsdName)", errno: EPERM) }
        return try FileBlockDevice(path: imagePath, sectorCount: sectorCount)
    }
    func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String { calls.append("waitSlice"); return "\(bsdName)s\(slice)" }
    func unmount(bsdName: String) throws { calls.append("unmount \(bsdName)") }
    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        calls.append("run \((tool as NSString).lastPathComponent)")
        return (tool.contains("fsck") ? fsckStatus : 0, "")
    }
    func mount(bsdName: String) throws { calls.append("mount \(bsdName)") }
}

@Suite struct FormatJobTests {
    let total: UInt64 = 134_217_728
    func setup() throws -> (FakeSystem, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        _ = try FileBlockDevice.createSparse(at: path, sectors: total)
        let d = DiskDescription(bsdName: "disk4", isWhole: true, isRemovable: true, isEjectable: true, isInternal: false,
                                isWritable: true, totalBytes: total * 512, blockSize: 512, containsBootVolume: false,
                                partitionFileSystems: ["exfat"], volumeUUIDs: ["U"])
        return (FakeSystem(desc: d, imagePath: path), path)
    }
    var req: FormatRequest { FormatRequest(bsdName: "disk4", expectedTotalBytes: total * 512, expectedVolumeUUID: "U", label: "CARD") }

    @Test func exFATCompletoNaOrdemCertaEConferido() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        var steps: [FormatStep] = []
        let r = FormatJob(system: sys).run(req) { steps.append($0) }
        #expect(r.ok, "\(String(describing: r.detail))")
        #expect(steps == FormatStep.allCases)
        #expect(sys.calls == ["describe", "suppress", "unmountWhole", "openRaw", "waitSlice", "unmount disk4s1",
                              "openRaw", "run fsck_exfat", "restore", "mount disk4s1", "restore"])
        let dev = try FileBlockDevice(path: path)
        #expect(PostFormatVerifier.issues(device: dev, plan: r.plan!).isEmpty)
    }

    @Test func discoRecusadoNaoEscreveNada() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        sys.desc.isInternal = true; sys.desc.isRemovable = false   // SSD interno do Mac
        let r = FormatJob(system: sys).run(req) { _ in }
        #expect(r.failure == .deviceRejected)
        #expect(!sys.calls.contains("openRaw") && !sys.calls.contains("unmountWhole"))
    }

    @Test func cartaoTrocadoViraCardChanged() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        sys.desc.volumeUUIDs = ["OUTRO"]
        #expect(FormatJob(system: sys).run(req) { _ in }.failure == .cardChanged)
    }

    @Test func desmontarFalhouNaoEscreve() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        sys.unmountFails = true
        let r = FormatJob(system: sys).run(req) { _ in }
        #expect(r.failure == .unmountFailed && !sys.calls.contains("openRaw") && sys.calls.contains("restore"))
    }

    @Test func fsckReprovandoViraFalha() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        sys.fsckStatus = 8
        #expect(FormatJob(system: sys).run(req) { _ in }.failure == .fsckFailed)
    }

    @Test func fat32ChamaNewfsComOsArgumentosDoPlano() throws {
        let t: UInt64 = 62_914_560
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try FileBlockDevice.createSparse(at: path, sectors: t)
        let d = DiskDescription(bsdName: "disk4", isWhole: true, isRemovable: true, isEjectable: true, isInternal: false,
                                isWritable: true, totalBytes: t * 512, blockSize: 512, containsBootVolume: false,
                                partitionFileSystems: ["msdos"], volumeUUIDs: [])
        let sys = FakeSystem(desc: d, imagePath: path)
        let r = FormatJob(system: sys).run(FormatRequest(bsdName: "disk4", expectedTotalBytes: t * 512, expectedVolumeUUID: nil, label: "A")) { _ in }
        // com o newfs falso o setor de boot não existe → a conferência acusa; o que importa aqui é a sequência
        #expect(sys.calls.contains("run newfs_msdos"))
        #expect(r.failure == .verifyFailed)
    }

    /// Cartão real (leitor embutido): abrir o disco cru falhou DEPOIS de desmontar. Nada foi escrito, então o
    /// cartão tem que voltar pro Finder; antes ele ficava desmontado e parecia ejetado.
    @Test func falhaAoAbrirDepoisDeDesmontarRemontaOCartao() throws {
        let (sys, path) = try setup(); defer { try? FileManager.default.removeItem(atPath: path) }
        sys.openRawFails = true
        let r = FormatJob(system: sys).run(req) { _ in }
        // EPERM no disco cru = o macOS negou (falta Acesso Total ao Disco ao ajudante): falha própria
        #expect(r.failure == .diskAccessDenied)
        #expect(sys.calls.contains("remountWhole"))
        #expect(r.detail?.contains("errno 1") == true)
    }
}
