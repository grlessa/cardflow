import Testing
import Foundation
@testable import FormatHelperCore
import CardFormatKit
import CardFormatXPC

/// Sequência REAL (DiskArbitration, nós /dev, fsck) numa imagem de disco do próprio usuário: sem root.
@Suite struct RealDiskSystemImageTests {
    /// Usa o sistema real, mas descreve a imagem como cartão (imagem aparece como disco interno/não removível)
    /// e abre o nó cru sem trava exclusiva (o nó de imagem é do usuário).
    final class ImageAsCard: DiskSystem {
        let real = RealDiskSystem()
        func describe(bsdName: String) throws -> DiskDescription {
            var d = try real.describe(bsdName: bsdName)
            d.isInternal = false; d.isRemovable = true
            return d
        }
        func unmountWhole(bsdName: String) throws { try real.unmountWhole(bsdName: bsdName) }
        func remountWhole(bsdName: String) { real.remountWhole(bsdName: bsdName) }
        func suppressAutomount(bsdName: String) { real.suppressAutomount(bsdName: bsdName) }
        func restoreAutomount() { real.restoreAutomount() }
        func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice {
            for n in ["/dev/r\(bsdName)", "/dev/\(bsdName)"] { chmod(n, 0o640) }
            return try FileBlockDevice(path: "/dev/r\(bsdName)", sectorCount: sectorCount)
        }
        func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String {
            let s = try real.waitForSlice(bsdName: bsdName, slice: slice, timeout: timeout)
            for n in ["/dev/r\(s)", "/dev/\(s)"] { chmod(n, 0o640) }
            return s
        }
        func unmount(bsdName: String) throws { try real.unmount(bsdName: bsdName) }
        func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) { try real.run(tool, args) }
        func mount(bsdName: String) throws { try real.mount(bsdName: bsdName) }
    }

    func attach(_ img: String) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", img]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first { $0.hasPrefix("/dev/disk") }!
        return String(line.split(whereSeparator: { $0 == " " || $0 == "\t" })[0]).replacingOccurrences(of: "/dev/", with: "")
    }
    func detach(_ bsd: String) {
        let d = Process(); d.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); d.arguments = ["detach", "-force", bsd]
        d.standardOutput = Pipe(); d.standardError = Pipe(); try? d.run(); d.waitUntilExit()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CARDFLOW_DISK_IMAGE_TESTS"] == "1"),
          arguments: [UInt64(134_217_728), UInt64(62_914_560)])
    func formataImagemDePontaAPonta(total: UInt64) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let img = dir.appendingPathComponent("c.img").path
        _ = try FileBlockDevice.createSparse(at: img, sectors: total)
        let bsd = try attach(img)
        defer { detach(bsd) }
        var steps: [FormatStep] = []
        let r = FormatJob(system: ImageAsCard()).run(
            FormatRequest(bsdName: bsd, expectedTotalBytes: total * 512, expectedVolumeUUID: nil, label: "CARDFLOW")) { steps.append($0) }
        #expect(r.ok, "\(String(describing: r.failure)) \(String(describing: r.detail))")
        #expect(steps.last == .remounting)
    }
}
