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

    @Test func gravaSoOJSONNaPastaOcultaEORelatorioVisivelNoProjeto() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = ManifestStore()
        _ = try store.write(sampleManifest(), eventRootIn: dest, eventName: "Conf")
        var b = sampleManifest(); b.offloadId = "fp2"; b.source.volumeName = "B002"
        _ = try store.write(b, eventRootIn: dest, eventName: "Conf")
        let hidden = try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("Conf/.cardflow").path)
        #expect(hidden.allSatisfy { $0.hasSuffix(".json") } && hidden.count == 2)
        let html = try String(contentsOf: dest.appendingPathComponent("Conf/Relatório Cardflow.html"), encoding: .utf8)
        #expect(html.contains("SONY_64G") && html.contains("B002"))   // um documento com os dois cartões
    }

    @Test func trocarIdiomaNaoDeixaDoisRelatorios() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = ManifestStore()
        _ = try store.write(sampleManifest(), eventRootIn: dest, eventName: "Conf", locale: Locale(identifier: "pt-BR"))
        _ = try store.write(sampleManifest(), eventRootIn: dest, eventName: "Conf", locale: Locale(identifier: "en"))
        let root = try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("Conf").path)
        #expect(root.contains("Cardflow Report.html") && !root.contains("Relatório Cardflow.html"))
    }

    @Test func formatarAtualizaORelatorio() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let store = ManifestStore()
        let json = try store.write(sampleManifest(), eventRootIn: dest, eventName: "Conf")
        _ = store.annotateCardFormatted(CardFormatRecord(at: Date(), fileSystem: "exFAT", clusterBytes: 131072, label: "SONY"),
                                        manifestJSONPaths: [json.path])
        let html = try String(contentsOf: store.reportURL(forManifestJSON: json), encoding: .utf8)
        #expect(html.contains("Formatado em") && html.contains("128 KB"))
    }

    @Test func fingerprintIsStableAndOrderIndependent() {
        let a = MediaFile(sourceURL: URL(fileURLWithPath: "/a"), relPath: "B.JPG", size: 10, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        let b = MediaFile(sourceURL: URL(fileURLWithPath: "/b"), relPath: "A.JPG", size: 20, type: .photo, captureDate: .init(timeIntervalSince1970: 0))
        #expect(CardFingerprint.compute(files: [a, b]) == CardFingerprint.compute(files: [b, a]))
    }

    @Test func anotaCartaoFormatadoSemPerderNada() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManifestStore()
        let m = Manifest(schemaVersion: 1, offloadId: "abc12345", appVersion: "0.4.0", presetName: "P", camera: "C",
                         startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 10),
                         source: .init(volumeName: "CARD", fingerprint: "f", fileCount: 1, bytes: 1), destinations: [],
                         files: [], unrecognized: [], totals: .init(photos: 0, videos: 0, audio: 0, sidecars: 0, verified: 0, failed: 0, skipped: 0))
        let url = try store.write(m, eventRootIn: dir, eventName: "EV")
        let rec = CardFormatRecord(at: Date(timeIntervalSince1970: 100), fileSystem: "exFAT", clusterBytes: 131_072, label: "CARD")
        #expect(store.annotateCardFormatted(rec, manifestJSONPaths: [url.path]).isEmpty)
        let back = try store.loadAll(eventRootIn: dir, eventName: "EV").first!
        #expect(back.cardFormatted == rec && back.offloadId == "abc12345")
    }
}
