import Testing
import Foundation
@testable import OffloadKit

@Suite struct ProjectReportTests {
    let pt = Locale(identifier: "pt-BR")

    func m(_ card: String, id: String, verified: Int = 2, failed: [String] = [], interrupted: Bool = false,
           at t: TimeInterval = 1_780_000_100) -> Manifest {
        var x = Manifest(schemaVersion: 2, offloadId: id, appVersion: "1.0.0", presetName: "Padrão", camera: "A",
            startedAt: Date(timeIntervalSince1970: t - 100), finishedAt: Date(timeIntervalSince1970: t),
            source: .init(volumeName: card, fingerprint: id, fileCount: verified, bytes: 4_000_000_000),
            destinations: ["/Volumes/SSD"],
            files: (1...verified).map { .init(sourceRelPath: "DCIM/\($0).JPG", destRelPath: "Casamento/Foto/\(card)_\($0).JPG",
                                              type: .photo, bytes: 2_000_000_000, xxhash64: "00112233aabbccdd", status: "verified") },
            unrecognized: [], totals: .init(photos: verified, videos: 0, audio: 0, sidecars: 0, verified: verified,
                                             failed: failed.count, skipped: 0), interrupted: interrupted)
        x.failedPaths = failed; x.projectName = "Casamento"
        return x
    }

    @Test func juntaOsCartoesEDaUmVereditoHumano() {
        let a = m("A001", id: "aaaa1111"), b = m("B002", id: "bbbb2222")
        let html = ProjectReport.html(manifests: [a, b], projectName: "Casamento", locale: pt)
        #expect(html.contains("Tudo conferido") && html.contains("Os 2 cartões estão salvos em 1 destino"))
        #expect(html.contains("A001") && html.contains("B002"))
        #expect(html.contains("id=\"\(ProjectReport.anchor(for: a))\"") && html.contains("id=\"\(ProjectReport.anchor(for: b))\""))
        #expect(ProjectReport.anchor(for: a) != ProjectReport.anchor(for: b))
        #expect(html.contains("<details"))                          // camada técnica recolhida
        #expect(html.contains("00112233aabbccdd"))                   // hash inteiro na camada técnica
        #expect(html.contains("8,0 GB"))                             // tamanho total no formato pt
        #expect(!html.contains("http://") && !html.contains("https://"))  // nada externo
    }
    @Test func retomadaDoMesmoCartaoNaoDuplica() {
        let html = ProjectReport.html(manifests: [m("A001", id: "aaaa1111", interrupted: true, at: 1_780_000_000),
                                                  m("A001", id: "aaaa1111", at: 1_780_000_500)],
                                      projectName: "Casamento", locale: pt)
        #expect(html.contains("Tudo conferido") && html.contains("O cartão está salvo"))
    }
    @Test func falhaMudaOVereditoEMostraOsArquivos() {
        let html = ProjectReport.html(manifests: [m("A001", id: "aaaa1111", failed: ["DCIM/9.JPG"])],
                                      projectName: "Casamento", locale: pt)
        #expect(html.contains("Não formate A001."))
        #expect(html.contains("DCIM/9.JPG"))
        #expect(!html.contains("Tudo conferido"))
    }
    @Test func interrompidaAvisa() {
        let html = ProjectReport.html(manifests: [m("A001", id: "aaaa1111", interrupted: true)],
                                      projectName: "Casamento", locale: pt)
        #expect(html.contains("Cópia interrompida"))
    }
    @Test func escondeCameraProvisoriaEDuracaoZero() {
        var x = m("A001", id: "aaaa1111"); x.camera = CameraMetadata.placeholder
        x.startedAt = x.finishedAt                                   // retomada sem nada novo
        let html = ProjectReport.html(manifests: [x], projectName: "Casamento", locale: pt)
        #expect(!html.contains("Câmera Cam01") && !html.contains("levou 0 s"))
        let normal = ProjectReport.html(manifests: [m("A001", id: "aaaa1111")], projectName: "Casamento", locale: pt)
        #expect(normal.contains("Câmera A") && normal.contains("levou 1 min 40 s"))
    }
    @Test func iconeDoDispositivoSegueOTipo() {
        #expect(DeviceIcon.key(for: nil) == "sd")
        #expect(DeviceIcon.key(for: MediaKind.sd.rawValue) == "sd")
        #expect(DeviceIcon.key(for: MediaKind.ssd.rawValue) == "external")
        #expect(DeviceIcon.key(for: MediaKind.cfexpressB.rawValue) == "removable")
        #expect(DeviceIcon.key(for: MediaKind.folder.rawValue) == "folder")
        var ssd = m("SSD01", id: "eeee5555"); ssd.source.mediaKind = MediaKind.ssd.rawValue
        let html = ProjectReport.html(manifests: [m("A001", id: "aaaa1111"), ssd], projectName: "Casamento", locale: pt)
        if DeviceIcon.dataURI("sd") != nil {   // ícone do macOS embutido uma vez por tipo, nada externo
            #expect(html.contains(".dev-sd{background-image:url(data:image/png;base64,"))
            #expect(html.contains(".dev-external{background-image:url(data:image/png;base64,"))
            #expect(html.components(separatedBy: "data:image/png").count == 3)
        }
    }
    @Test func escapaNomes() {
        var x = m("<b>", id: "cccc3333"); x.files[0].destRelPath = "Casamento/<script>.JPG"
        let html = ProjectReport.html(manifests: [x], projectName: "A & B", locale: pt)
        #expect(!html.contains("<script>.JPG") && html.contains("&lt;script&gt;.JPG") && html.contains("A &amp; B"))
        #expect(!html.contains("<b>"))
    }
    @Test func segueOIdioma() {
        let en = ProjectReport.html(manifests: [m("A001", id: "aaaa1111")], projectName: "Wedding", locale: Locale(identifier: "en"))
        #expect(en.contains("All verified") && en.contains("lang=\"en\"") && !en.contains("Cartões"))
        #expect(ProjectReport.fileName(locale: Locale(identifier: "es")) == "Informe Cardflow.html")
    }
    @Test func manifestoAntigoSemCamposNovosEntra() throws {
        let json = #"{"schemaVersion":2,"offloadId":"dddd4444","appVersion":"0.3.0","presetName":"P","camera":"A","startedAt":"2026-06-01T10:00:00Z","finishedAt":"2026-06-01T10:05:00Z","source":{"volumeName":"OLD","fingerprint":"f","fileCount":0,"bytes":0},"destinations":[],"files":[],"unrecognized":[],"totals":{"photos":0,"videos":0,"audio":0,"sidecars":0,"verified":0,"failed":0,"skipped":0}}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let old = try dec.decode(Manifest.self, from: Data(json.utf8))
        #expect(old.projectName == nil && old.failedPaths == nil && old.excludedByChoice == nil)
        #expect(ProjectReport.html(manifests: [old], projectName: "P", locale: pt).contains("OLD"))
    }
}

@Suite struct ProjectReportAuxTests {
    @Test func auxiliaresAParte() {
        var x = Manifest(schemaVersion: 2, offloadId: "aux1", appVersion: "1.0.0", presetName: "P", camera: "",
                         startedAt: Date(timeIntervalSince1970: 1_780_000_000), finishedAt: Date(timeIntervalSince1970: 1_780_000_100),
                         source: .init(volumeName: "A001", fingerprint: "aux1", fileCount: 1, bytes: 10), destinations: ["/Volumes/SSD"],
                         files: [.init(sourceRelPath: "CLIP/C0001.MP4", destRelPath: "EV/C0001.MP4", type: .video, bytes: 10, xxhash64: "00", status: "verified")],
                         unrecognized: [], totals: .init(photos: 0, videos: 1, audio: 0, sidecars: 0, verified: 1, failed: 0, skipped: 0))
        x.excludedByChoice = ["CLIP/C0001M01.XML", "CLIP/C0002M01.XML", "DCIM/DSC1.JPG"]
        let html = ProjectReport.html(manifests: [x], projectName: "EV", locale: Locale(identifier: "pt-BR"))
        #expect(html.contains("1 ficou no cartão por escolha"))
        #expect(html.contains("2 arquivos auxiliares (XML, THM…) ficaram no cartão"))
    }
}
