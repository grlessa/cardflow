import Foundation
import Testing
import OffloadKit
@testable import CardflowApp

/// Cartão com várias câmeras: entradas por câmera detectada, nomes e câmeras deixadas de fora.
@MainActor
@Suite struct CameraEntriesTests {
    private func file(_ rel: String, _ type: FileType) -> MediaFile {
        MediaFile(sourceURL: URL(fileURLWithPath: "/Volumes/X/" + rel), relPath: rel, size: 10, type: type,
                  captureDate: Date(), preserve: false)
    }
    private func card() -> CardSession {
        let c = CardSession(volume: ExternalVolume(url: URL(fileURLWithPath: "/Volumes/X"), name: "X", isRemovable: true, isInternal: false))
        c.scanned = [file("DCIM/100GOPRO/GX01.MP4", .video), file("DCIM/100GOPRO/GX02.MP4", .video),
                     file("DCIM/100CANON/IMG_1.JPG", .photo), file("ZOOM/ZOOM0001.WAV", .audio)]
        c.detectedByGroup = ["DCIM/100GOPRO": "GoPro", "DCIM/100CANON": "R5"]
        c.defaultCamera = "CAM A"
        return c
    }

    @Test func umaEntradaPorCameraEOResto() {
        let c = card()
        let e = c.cameraEntries
        #expect(e.map(\.id) == ["GoPro", "", "R5"] || e.map(\.id) == ["GoPro", "R5", ""])
        #expect(c.isMultiCamera)
        #expect(c.cameraName(e.first { $0.id == "" }!) == "CAM A")   // sem câmera: o nome de reserva
    }

    @Test func nomeEscolhidoVaiProsArquivosDaCamera() {
        let c = card()
        c.cameraNames["GoPro"] = "CAM B"
        #expect(c.camerasByGroup["DCIM/100GOPRO"] == "CAM B")
        #expect(c.camerasByGroup["DCIM/100CANON"] == "R5")
        #expect(c.camerasByGroup["ZOOM"] == "CAM A")
    }

    @Test func cameraDeForaViraGruposExcluidos() {
        let c = card()
        c.excludedCameras = ["R5"]
        #expect(c.excludedGroups == ["DCIM/100CANON"])
    }

    @Test func umaCameraSoNaoMapeiaNada() {
        let c = card()
        c.scanned = [file("DCIM/100GOPRO/GX01.MP4", .video)]
        #expect(!c.isMultiCamera)
        #expect(c.camerasByGroup.isEmpty)
    }
}
