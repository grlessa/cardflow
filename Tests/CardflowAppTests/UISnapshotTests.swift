import Testing
import SwiftUI
import AppKit
@testable import CardflowApp
@testable import OffloadKit

/// Capturas da janela inteira em cada estado, pra conferência visual sem depender da tela do Mac nem de
/// permissões. Só roda com CARDFLOW_SNAPSHOT_DIR=/pasta swift test --filter UISnapshotTests.
@MainActor @Suite(.serialized) struct UISnapshotTests {
    let dir = ProcessInfo.processInfo.environment["CARDFLOW_SNAPSHOT_DIR"]

    // MARK: Cenário

    func files(prefix: String, photos: Int, videos: Int, audios: Int) -> [MediaFile] {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        var out: [MediaFile] = []
        for i in 0..<photos {
            out.append(MediaFile(sourceURL: URL(fileURLWithPath: "/x"), relPath: "DCIM/100MSDCF/DSC0\(4100 + i).ARW",
                                 size: 48_200_000, type: .photo, captureDate: base.addingTimeInterval(Double(i) * 40)))
        }
        for i in 0..<videos {
            out.append(MediaFile(sourceURL: URL(fileURLWithPath: "/x"), relPath: "PRIVATE/M4ROOT/CLIP/C00\(10 + i).MP4",
                                 size: 2_310_000_000, type: .video, captureDate: base.addingTimeInterval(3600 + Double(i) * 300)))
        }
        for i in 0..<audios {
            out.append(MediaFile(sourceURL: URL(fileURLWithPath: "/x"), relPath: "ZOOM000\(i)/ZOOM000\(i)_LR.WAV",
                                 size: 412_000_000, type: .audio, captureDate: base.addingTimeInterval(5400 + Double(i) * 60)))
        }
        return out
    }

    func makeModel(cards: Int = 2, withDestination: Bool = true) async throws -> (AppModel, URL) {
        let m = AppModel(formatter: FakeFormatter())
        m.presets = [.factoryDefault]
        m.projectName = "Casamento Ana e João"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        let destURL = root.appendingPathComponent("SSD Edição")
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let sd = DeviceTraits(protocolName: "Secure Digital", deviceModel: "Built In SDXC Reader", mediaName: nil,
                              isRemovableMedia: true, isInternalDevice: true, fileSystem: "exfat")
        let cfx = DeviceTraits(protocolName: "USB", deviceModel: "CFexpress Type B Card Reader", mediaName: nil,
                               isRemovableMedia: true, isInternalDevice: false, fileSystem: "exfat")
        let ssd = DeviceTraits(protocolName: "USB", deviceModel: "Samsung PSSD T7", mediaName: nil,
                               isRemovableMedia: false, isInternalDevice: false, fileSystem: "apfs")
        var vols: [ExternalVolume] = []
        let names = ["A001", "B002", "C003"]
        for i in 0..<cards {
            let u = root.appendingPathComponent(names[i])
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            vols.append(ExternalVolume(url: u, name: names[i], isRemovable: true, isInternal: i == 0,
                                       totalBytes: i == 0 ? 128_000_000_000 : 256_000_000_000,
                                       physicalDeviceID: "disk\(4 + i)", volumeUUID: names[i], traits: i == 0 ? sd : cfx))
        }
        if withDestination {
            vols.append(ExternalVolume(url: destURL, name: "SSD Edição", isRemovable: true, isInternal: false,
                                       totalBytes: 2_000_000_000_000, physicalDeviceID: "disk9", volumeUUID: "SSD", traits: ssd))
        }
        m.watcher.volumes = vols
        m.forcedSources = Set(vols.prefix(cards).map(\.id))
        if withDestination { m.forcedDestinations = [destURL.path] }
        m.reconcileVolumes()
        if withDestination { m.setUserDestination(destURL) }
        for (i, c) in m.cards.enumerated() {
            c.scanTask?.cancel()
            c.scanned = files(prefix: c.volume.name, photos: i == 0 ? 248 : 0, videos: i == 0 ? 12 : 31, audios: i == 0 ? 3 : 0)
            c.phase = .ready
            c.camera = i == 0 ? "ILCE-7M4" : "FX6"
            m.recomputePreview(c)
        }
        for _ in 0..<300 where !m.cards.allSatisfy({ $0.preview != nil }) { try? await Task.sleep(nanoseconds: 10_000_000) }
        return (m, root)
    }

    func capture(_ m: AppModel, _ name: String, size: CGSize = CGSize(width: 1100, height: 720),
                 dark: Bool = false, inspector: Bool = false) async throws {
        guard let dir else { return }
        UserDefaults.standard.set(inspector, forKey: "cardflow.inspectorShown")
        UserDefaults.standard.set(true, forKey: "cardflow.didOnboard")
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RootView()
            .environment(m)
            .environmentObject(UpdateController(startingUpdater: false)))
        let win = NSWindow(contentRect: NSRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.toolbarStyle = .unified
        win.contentView = host
        win.orderFront(nil)
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.025)); try? await Task.sleep(nanoseconds: 5_000_000) }
        let frameView = win.contentView!.superview ?? host
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(dark ? "-escuro" : "").png"))
        win.orderOut(nil)
    }

    // MARK: Estados

    @Test func estados() async throws {
        guard dir != nil else { return }
        var (m, root) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        m.selection = .card(m.cards[0].id)
        try await capture(m, "01-pronto")
        try await capture(m, "01-pronto", dark: true)
        try await capture(m, "02-pronto-inspetor", inspector: true)
        try await capture(m, "03-minima", size: CGSize(width: 820, height: 560))

        let a = m.cards[0], b = m.cards[1]
        a.phase = .running(OffloadProgress(phase: .copying, filesDone: 120, filesTotal: 263, bytesDone: 21_400_000_000, bytesTotal: 41_200_000_000))
        a.startedAt = Date().addingTimeInterval(-95)
        b.phase = .queued
        try await capture(m, "04-copiando")
        m.selection = .card(b.id)
        try await capture(m, "05-na-fila")

        m.selection = .card(a.id)
        a.phase = .finished(OffloadOutcome(verifiedCount: 263, failures: [], unrecognized: [], skipped: [],
                                           manifestPaths: ["/tmp/x/.cardflow/manifest-1.json"]))
        a.lastElapsed = 742
        try await capture(m, "06-conferido")
        try await capture(m, "06-conferido", dark: true)
        a.phase = .finished(OffloadOutcome(verifiedCount: 260, failures: ["DCIM/100MSDCF/DSC04110.ARW"], unrecognized: [], skipped: []))
        try await capture(m, "07-falhou")
        a.phase = .ready
        a.formatState = .formatting(.writingFileSystem)
        try await capture(m, "08-formatando")

        (m, root) = try await makeModel(cards: 0)
        try await capture(m, "09-sem-cartao")
        try await capture(m, "09-sem-cartao", dark: true)
        (m, root) = try await makeModel(cards: 1, withDestination: false)
        try await capture(m, "10-sem-destino")
    }
}
