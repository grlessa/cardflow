import Testing
import Foundation
@testable import OffloadKit

/// Cartão que passou por várias câmeras: cada arquivo leva a câmera da pasta dele, dá pra deixar uma
/// câmera de fora, e a câmera deixada de fora trava a formatação (é material de outra pessoa).
@Suite struct MultiCameraCardTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func put(_ card: URL, _ rel: String) throws {
        let u = card.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rel.utf8).write(to: u)
    }
    var preset: Preset {
        var p = Preset.flatDefault; p.evento = "EV"
        p.folderStructure = "{projeto}/{camera}"
        return p
    }
    func service() -> CopyService { CopyService(preset: preset, spaceProvider: MultiCamSpace(), timeZone: .current) }
    func card(_ w: URL) throws -> URL {
        let c = w.appendingPathComponent("CARD")
        try put(c, "DCIM/100GOPRO/GX010001.MP4")
        try put(c, "DCIM/100CANON/IMG_0001.JPG")
        try put(c, "PRIVATE/M4ROOT/CLIP/C0001.MP4")
        return c
    }
    let cams = ["DCIM/100GOPRO": "HERO12", "DCIM/100CANON": "R5", "PRIVATE/M4ROOT/CLIP": "FX30"]

    @Test func grupoEhAPastaDoArquivo() {
        let f = MediaFile(sourceURL: URL(fileURLWithPath: "/x"), relPath: "DCIM/100GOPRO/GX010001.MP4", size: 1,
                          type: .video, captureDate: Date(), preserve: false)
        #expect(CameraGroups.key(for: f) == "DCIM/100GOPRO")
    }

    @Test func cadaArquivoLevaACameraDaPasta() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let c = try card(w), dest = w.appendingPathComponent("SSD")
        let out = try service().run(cardRoot: c, chosenMedia: .both, destinations: [dest], camera: "CAM A", cameras: cams)
        #expect(out.failures.isEmpty)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/HERO12/GX010001.MP4").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/R5/IMG_0001.JPG").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/FX30/C0001.MP4").path))
    }

    @Test func cameraDeFicaNoCartaoETravaFormatar() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let c = try card(w), dest = w.appendingPathComponent("SSD")
        let out = try service().run(cardRoot: c, chosenMedia: .both, destinations: [dest], camera: "CAM A",
                                    cameras: cams, excludedGroups: ["DCIM/100CANON"])
        #expect(out.verifiedCount == 2)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("EV/R5").path))
        let r = try CardWipeCheck.evaluate(cardRoot: c, preset: preset,
                                           choices: WipeChoices(chosenMedia: .both, capturedIn: nil, excludedGroups: ["DCIM/100CANON"]),
                                           destinations: [dest])
        #expect(!r.canWipe)
        #expect(r.notVerified == ["DCIM/100CANON/IMG_0001.JPG"])
    }

    @Test func previaNaoContaACameraDeFora() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let c = try card(w)
        let scanned = try CardScanner(classifier: FileClassifier(preset: preset)).scan(cardRoot: c)
        let s = service()
        #expect(s.selectedFiles(scanned, chosenMedia: .both, capturedIn: nil, excludedGroups: ["DCIM/100GOPRO"]).count == 2)
    }
}

private struct MultiCamSpace: FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64 { Int64.max }
}

@Suite struct CameraBrandHintTests {
    @Test func marcaPelaPasta() {
        #expect(CameraGroups.brandHint(forGroup: "DCIM/100GOPRO") == "GoPro")
        #expect(CameraGroups.brandHint(forGroup: "DCIM/101MSDCF") == "Sony")
        #expect(CameraGroups.brandHint(forGroup: "DCIM/100_PANA") == "Panasonic")
        #expect(CameraGroups.brandHint(forGroup: "PRIVATE/M4ROOT/CLIP") == nil)
        #expect(CameraGroups.brandHint(forGroup: "") == nil)
    }
}

@Suite struct KeptCameraOutcomeTests {
    @Test func cameraDeForaNaoLiberaFormatar() {
        let o = OffloadOutcome(verifiedCount: 2, failures: [], unrecognized: [], skipped: [], cameraFilesLeft: 1)
        #expect(!o.canSafelyFormatCard)
        #expect(o.copiedKeepingCameras)
        let ok = OffloadOutcome(verifiedCount: 2, failures: [], unrecognized: [], skipped: [])
        #expect(ok.canSafelyFormatCard && !ok.copiedKeepingCameras)
    }

    @Test func relatorioAvisaQueNaoPodeFormatar() {
        var m = Manifest(schemaVersion: 2, offloadId: "kk11", appVersion: "1.0.0", presetName: "P", camera: "GoPro",
                         startedAt: Date(timeIntervalSince1970: 1_780_000_000), finishedAt: Date(timeIntervalSince1970: 1_780_000_100),
                         source: .init(volumeName: "A001", fingerprint: "kk11", fileCount: 1, bytes: 10),
                         destinations: ["/Volumes/SSD"],
                         files: [.init(sourceRelPath: "DCIM/100GOPRO/GX01.MP4", destRelPath: "EV/GX01.MP4", type: .video,
                                       bytes: 10, xxhash64: "00", status: "verified")],
                         unrecognized: [], totals: .init(photos: 0, videos: 1, audio: 0, sidecars: 0, verified: 1, failed: 0, skipped: 0))
        m.keptCameras = ["FX30"]
        let html = ProjectReport.html(manifests: [m], projectName: "EV", locale: Locale(identifier: "pt-BR"))
        #expect(html.contains("Copiado, mas não formate A001."))
        #expect(html.contains("Ficaram no cartão os arquivos de FX30"))
        #expect(!html.contains("Tudo conferido"))
    }

    @Test func copiaContaOQueFicouDaCamera() throws {
        let w = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: w) }
        let c = w.appendingPathComponent("CARD")
        for rel in ["DCIM/100GOPRO/GX01.MP4", "PRIVATE/M4ROOT/CLIP/C0001.MP4"] {
            let u = c.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(rel.utf8).write(to: u)
        }
        var p = Preset.flatDefault; p.evento = "EV"
        let out = try CopyService(preset: p, spaceProvider: KeptSpace(), timeZone: .current)
            .run(cardRoot: c, chosenMedia: .both, destinations: [w.appendingPathComponent("SSD")], camera: "CAM A",
                 cameras: ["DCIM/100GOPRO": "GoPro", "PRIVATE/M4ROOT/CLIP": "FX30"], excludedGroups: ["PRIVATE/M4ROOT/CLIP"])
        #expect(out.cameraFilesLeft == 1 && !out.canSafelyFormatCard && out.copiedKeepingCameras)
        let manifest = try ManifestStore().loadAll(eventRootIn: w.appendingPathComponent("SSD"), eventName: "EV").first
        #expect(manifest?.keptCameras == ["FX30"])
    }
}

private struct KeptSpace: FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64 { Int64.max }
}
