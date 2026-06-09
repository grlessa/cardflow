import Testing
import Foundation
@testable import OffloadKit

@Suite struct OffloadManifestTests {
    private struct Enough: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { .max } }

    @Test func manifestLoteRoundTripsAndDecodesNilFromOld() throws {
        let m = Manifest(
            schemaVersion: 2, offloadId: "fp", appVersion: "x", presetName: "p", camera: "Cam",
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
            source: .init(volumeName: "SD", fingerprint: "fp", fileCount: 1, bytes: 100),
            destinations: ["/d"], files: [], unrecognized: [],
            totals: .init(photos: 0, videos: 0, audio: 0, sidecars: 0, verified: 0, failed: 0, skipped: 0),
            interrupted: false, lote: 3)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(Manifest.self, from: data).lote == 3)
        // manifesto antigo (sem a chave "lote") decodifica como nil
        var s = String(data: data, encoding: .utf8)!
        s = s.replacingOccurrences(of: "\"lote\":3,", with: "")
            .replacingOccurrences(of: ",\"lote\":3", with: "")
            .replacingOccurrences(of: "\"lote\":3", with: "")
        #expect(try JSONDecoder().decode(Manifest.self, from: Data(s.utf8)).lote == nil)
    }
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func copiesSidecarAsideAndWritesManifest() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }

        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(),
                                  clock: { Date(timeIntervalSince1970: 1_780_000_000) },
                                  activityKeeper: NoopActivityKeeper())
        let outcome = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")

        // FakeCard tem 1 sidecar (.XML) → copiado à parte, fora de FOTO/VIDEO
        #expect(outcome.sidecarsCopied == 1)
        let sidecar = dest.appendingPathComponent("Conferencia-Junho-2026/.cardflow/sidecars/PRIVATE/M4ROOT/CLIP/C0001M01.XML")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        // mídia continua em FOTO/VIDEO, sem sidecar no meio
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Conferencia-Junho-2026/Foto/DSC00001.JPG").path))

        // manifesto gravado e legível
        #expect(outcome.manifestPaths.count == 1)
        let manifests = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Conferencia-Junho-2026")
        #expect(manifests.count == 1)
        #expect(manifests.first?.totals.verified == 3)
        #expect(manifests.first?.totals.photos == 2)
        #expect(manifests.first?.totals.videos == 1)
    }

    @Test func eventoComBarraSaneadoEmTodasAsArvores() throws {
        // "Culto 09/06" não pode separar mídia da árvore de sidecar/manifesto.
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        var preset = Preset.sampleConferencia
        preset.evento = "Culto 09/06"
        let service = CopyService(preset: preset, spaceProvider: Enough(),
                                  clock: { Date(timeIntervalSince1970: 1_780_000_000) },
                                  activityKeeper: NoopActivityKeeper())
        let outcome = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")

        let fm = FileManager.default
        // mídia, sidecar e manifesto: TODOS na mesma árvore saneada "Culto 09-06"
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Culto 09-06/Foto/DSC00001.JPG").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Culto 09-06/.cardflow/sidecars/PRIVATE/M4ROOT/CLIP/C0001M01.XML").path))
        #expect(outcome.manifestPaths.first?.contains("Culto 09-06/") == true)
        // a barra NÃO virou subpasta "Culto 09"/"06"
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Culto 09").path))
    }

    @Test func sidecarIsListedInManifestAndCountedOnRerun() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(),
                                  clock: { Date(timeIntervalSince1970: 1_780_000_000) },
                                  activityKeeper: NoopActivityKeeper())

        _ = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        let m1 = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Conferencia-Junho-2026")
        // sidecar deve aparecer LISTADO no manifesto, não só no número agregado
        #expect(m1.first?.files.contains { $0.type == .sidecar } == true)
        #expect(m1.first?.totals.sidecars == 1)

        // re-run: sidecar já presente não pode sumir dos contadores do manifesto
        _ = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        let latest = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Conferencia-Junho-2026")
            .max(by: { $0.finishedAt < $1.finishedAt })
        #expect(latest?.files.contains { $0.type == .sidecar } == true)
        #expect(latest?.totals.sidecars == 1)
    }

    @Test func totalsCinemaDecodificaAusenteComoZero() throws {
        // manifesto do Plano 7 (sem a chave "cinema") decodifica com cinema == 0
        let json = """
        {"photos":2,"videos":1,"audio":0,"sidecars":1,"verified":4,"failed":0,"skipped":0}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(Manifest.Totals.self, from: json)
        #expect(t.cinema == 0)
        #expect(t.photos == 2)
    }
}
