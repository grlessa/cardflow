import Testing
import Foundation
@testable import OffloadKit

@Suite struct ManifestStoreTests {
    func sampleManifest() -> Manifest {
        Manifest(
            schemaVersion: 2, offloadId: "fp1", appVersion: "0.1.0",
            presetName: "Conf", camera: "Cam01",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_780_000_100),
            source: .init(volumeName: "SONY_64G", fingerprint: "fp1", fileCount: 2, bytes: 4096),
            destinations: ["/Volumes/SSD/Conf"],
            files: [.init(sourceRelPath: "DCIM/1.JPG", destRelPath: "Conf/FOTO/1.JPG",
                          type: .photo, bytes: 2048, xxhash64: "aabb", status: "verified")],
            unrecognized: ["x.dat"],
            totals: .init(photos: 1, videos: 1, audio: 0, sidecars: 0, verified: 2, failed: 0, skipped: 0)
        )
    }

    @Test func writeThenLoadRoundTrips() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        let store = ManifestStore()
        let m = sampleManifest()
        let url = try store.write(m, eventRootIn: dest, eventName: "Conf")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try store.loadAll(eventRootIn: dest, eventName: "Conf")
        #expect(loaded.count == 1)
        #expect(loaded.first == m)
    }

    // #29: um manifesto inválido (JSON truncado por um crash antigo) é ignorado, mas os válidos carregam.
    @Test func loadAllSkipsCorruptManifestButLoadsValidOnes() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = ManifestStore()
        _ = try store.write(sampleManifest(), eventRootIn: dest, eventName: "Conf")
        // injeta um manifesto corrompido na mesma pasta
        let dir = dest.appendingPathComponent("Conf").appendingPathComponent(".cardflow")
        try Data("{ truncado".utf8).write(to: dir.appendingPathComponent("manifest-quebrado.json"))
        let loaded = try store.loadAll(eventRootIn: dest, eventName: "Conf")
        #expect(loaded.count == 1)   // só o válido
    }

    // #19: o histórico varre TODAS as pastas de evento do destino, mais recente primeiro.
    @Test func loadAllInDestinationGathersEveryEventNewestFirst() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = ManifestStore()
        var antigo = sampleManifest(); antigo.presetName = "Antigo"
        antigo.finishedAt = Date(timeIntervalSince1970: 1_000_000)
        var novo = sampleManifest(); novo.presetName = "Novo"
        novo.finishedAt = Date(timeIntervalSince1970: 2_000_000)
        _ = try store.write(antigo, eventRootIn: dest, eventName: "Culto A")
        _ = try store.write(novo, eventRootIn: dest, eventName: "Culto B")
        let all = store.loadAllInDestination(dest)
        #expect(all.count == 2)
        #expect(all.first?.presetName == "Novo")   // mais recente primeiro
    }

    @Test func humanSummaryMentionsTotals() {
        let s = ManifestStore().humanSummary(sampleManifest())
        #expect(s.contains("1 foto"))
        #expect(s.contains("1 vídeo"))
        #expect(s.contains("clipe(s) de cinema"))
        #expect(s.contains("Cam01"))
    }

    // O recibo .txt segue o idioma efetivo: em en, rótulos e cabeçalho ficam em inglês.
    @Test func humanSummaryFollowsEnglishLocale() {
        let s = ManifestStore().humanSummary(sampleManifest(), locale: Locale(identifier: "en"))
        #expect(s.contains("Offload: Conf"))
        #expect(s.contains("camera Cam01"))
        #expect(s.contains("Card: SONY_64G"))
        #expect(s.contains("1 photo(s)"))
        #expect(s.contains("1 video(s)"))
        #expect(s.contains("cinema clip(s)"))
        #expect(s.contains("Verified:"))
        #expect(s.contains("Unrecognized:"))
        // não vaza pt-BR no recibo em inglês
        #expect(!s.contains("Cartão"))
        #expect(!s.contains("Verificados"))
    }

    @Test func htmlReportIsCredibleProof() {
        let html = ManifestStore().htmlReport(sampleManifest())
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("Cardflow"))
        #expect(html.contains("2 arquivos copiados e verificados byte a byte"))  // veredito (totals.verified)
        #expect(html.contains("Conf/FOTO/1.JPG"))   // o caminho do arquivo na tabela
        #expect(html.contains("aabb"))               // o hash de verificação (a prova)
        #expect(html.contains("byte a byte"))        // nota de rodapé
        #expect(html.contains("SONY_64G"))           // o cartão
    }

    @Test func htmlReportFollowsEnglishLocale() {
        let html = ManifestStore().htmlReport(sampleManifest(), locale: Locale(identifier: "en"))
        #expect(html.contains("Copy receipt"))
        #expect(html.contains("copied and verified byte for byte"))
        #expect(html.contains("lang=\"en\""))
        #expect(!html.contains("Comprovante"))       // não vaza pt
    }

    @Test func htmlReportEscapesFileNames() {
        var m = sampleManifest()
        m.files = [.init(sourceRelPath: "a", destRelPath: "Foto/<script>x</script>.jpg",
                         type: .photo, bytes: 10, xxhash64: "ff", status: "verified")]
        let html = ManifestStore().htmlReport(m)
        #expect(html.contains("&lt;script&gt;"))     // nome de arquivo escapado
        #expect(!html.contains("<script>"))          // nenhuma tag <script> crua (injeção)
    }

    @Test func writeAlsoWritesHtmlReceipt() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let url = try ManifestStore().write(sampleManifest(), eventRootIn: dest, eventName: "Conf")
        let html = url.deletingPathExtension().appendingPathExtension("html")
        #expect(FileManager.default.fileExists(atPath: html.path))
    }

    @Test func fingerprintIsStableAndOrderIndependent() {
        let a = MediaFile(sourceURL: URL(fileURLWithPath: "/a"), relPath: "B.JPG", size: 10, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        let b = MediaFile(sourceURL: URL(fileURLWithPath: "/b"), relPath: "A.JPG", size: 20, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        #expect(CardFingerprint.compute(files: [a, b]) == CardFingerprint.compute(files: [b, a]))
    }
}
