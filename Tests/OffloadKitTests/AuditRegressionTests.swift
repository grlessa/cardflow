import Testing
import Foundation
@testable import OffloadKit

@Suite struct AuditRegressionTests {
    private struct AlwaysEnoughSpace: FreeSpaceProviding {
        func availableBytes(at url: URL) throws -> Int64 { Int64.max }
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// P0: manifesto de 2 destinos não pode duplicar registros nem contaminar um disco com o sucesso do outro.
    @Test func manifestoPorDestinoNaoDuplicaNemContaminaOutroDisco() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD_B")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        let bytesB = Data("BBBB-4096".utf8)
        let bytesA = Data("AAAA-4096".utf8)   // mesmo tamanho, conteúdo diferente (Cartão A já no SSD1)
        try bytesB.write(to: card.appendingPathComponent("DCIM/100/DSC00001.JPG"))

        let d1 = work.appendingPathComponent("SSD1")
        let d2 = work.appendingPathComponent("SSD2")
        // Caso 1: cópia normal pra 2 destinos não duplica registros em nenhum manifesto
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let normal = try svc.run(cardRoot: card, chosenMedia: .both, destinations: [d1, d2], camera: "Cam")
        #expect(normal.failures.isEmpty)
        let ms1 = try ManifestStore().loadAll(eventRootIn: d1, eventName: "Offload")
        let ms2 = try ManifestStore().loadAll(eventRootIn: d2, eventName: "Offload")
        #expect(ms1.first?.files.count == 1)
        #expect(ms2.first?.files.count == 1)

        // Caso 2: contaminação cruzada — SSD3 já tem arquivo do Cartão A no caminho desejado;
        // cópia do Cartão B falha verify no SSD3 (caminho desambiguado) e passa no SSD4 (caminho desejado).
        let d3 = work.appendingPathComponent("SSD3")
        let d4 = work.appendingPathComponent("SSD4")
        let pre = d3.appendingPathComponent("Offload/Foto/DSC00001.JPG")
        try fm.createDirectory(at: pre.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytesA.write(to: pre)

        struct FailVerifyOnSSD3: FileCopying {
            let real = FileCopier()
            func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void, isCancelled: () -> Bool) throws -> UInt64 {
                try real.copy(source: source, to: destinations, onChunk: onChunk, isCancelled: isCancelled)
            }
            func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool {
                if url.path.contains("/SSD3/") { return false }
                return try real.verify(expectedHash: expectedHash, fileAt: url)
            }
        }
        let svcFail = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                                  timeZone: .current, copier: FailVerifyOnSSD3())
        let out = try svcFail.run(cardRoot: card, chosenMedia: .both, destinations: [d3, d4], camera: "Cam")
        #expect(!out.failures.isEmpty)
        let m3 = try ManifestStore().loadAll(eventRootIn: d3, eventName: "Offload").first
        let m4 = try ManifestStore().loadAll(eventRootIn: d4, eventName: "Offload").first
        // SSD3 falhou: manifesto do SSD3 NÃO pode afirmar que tem DSC00001.JPG do Cartão B
        #expect(m3?.files.isEmpty == true)
        #expect(m4?.files.count == 1)
    }

    /// P0: descarregar clipe de cinema (.braw) em 2 níveis (<Projeto>/<Cartão>/A001.braw) não pode transformar o SSD em cartão.
    @Test func offloadDeCinemaNaoTransformaDestinoEmCartao() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("BMD01")
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try Data("braw-data".utf8).write(to: card.appendingPathComponent("A001.braw"))
        let ssd = work.appendingPathComponent("SSD_DEST")
        try fm.createDirectory(at: ssd, withIntermediateDirectories: true)

        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let o = try svc.run(cardRoot: card, chosenMedia: .both, destinations: [ssd], camera: "Cam")
        #expect(o.verifiedCount == 1)

        let vol = ExternalVolume(url: ssd, name: "SSD_DEST", isRemovable: false, isInternal: false)
        #expect(!CardDetection.isCard(vol))
    }

    /// P1: PhysicalDisk funciona em subpastas (não só no ponto de montagem exato).
    @Test func physicalDiskResolveEmSubpasta() {
        let rootBSD = PhysicalDisk.wholeDiskBSD(for: URL(fileURLWithPath: "/"))
        let subBSD = PhysicalDisk.wholeDiskBSD(for: FileManager.default.temporaryDirectory)
        #expect(rootBSD != nil)
        #expect(subBSD == rootBSD)
    }

    /// P1: prévia não confia em manifesto órfão quando a mídia foi removida/movida do destino.
    @Test func previaNaoTravaQuandoMidiaDoManifestoFoiApagada() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card.root, chosenMedia: .photo, destinations: [dest], camera: "Cam")

        // Usuário move/apaga a pasta Foto e desconhecidos, mas `.cardflow/manifest-*.json` fica para trás
        try FileManager.default.removeItem(at: dest.appendingPathComponent("Offload/Foto"))
        try? FileManager.default.removeItem(at: dest.appendingPathComponent("Offload/.cardflow/desconhecidos"))
        let pv = try svc.preview(cardRoot: card.root, chosenMedia: .photo, destinations: [dest])
        #expect(pv.alreadyPresent == 0)
        #expect(pv.remainingBytes == pv.totalBytes)
    }

    /// P1: relatório de uma cópia de 0 arquivos NÃO pode dizer "pode ser formatado".
    @Test func relatorioDeZeroArquivosMostraAvisoENaoVerde() {
        let m = Manifest(
            schemaVersion: 2, offloadId: "empty-1", appVersion: "1.0.2", presetName: "Padrão", camera: "CAM A",
            startedAt: Date(), finishedAt: Date(),
            source: .init(volumeName: "SD", fingerprint: "empty-1", fileCount: 0, bytes: 0),
            destinations: ["/Volumes/SSD"], files: [], unrecognized: [],
            totals: .init(photos: 0, videos: 0, audio: 0, cinema: 0, sidecars: 0, verified: 0, failed: 0, skipped: 0)
        )
        let html = ProjectReport.html(manifests: [m], projectName: "Teste", locale: Locale(identifier: "pt-BR"))
        #expect(html.contains("hero warn"))
        #expect(!html.contains("pode ser formatado"))
    }

    /// P1: AppleDouble `._*` dentro de bundle de cinema não preserva; cinema em PRIVATE/XDROOT não engole PRIVATE/M4ROOT.
    @Test func preservePlannerIgnoraAppleDoubleESeparaPastasEmPrivate() {
        func mf(_ rel: String, _ t: FileType) -> MediaFile {
            MediaFile(sourceURL: URL(fileURLWithPath: "/c/\(rel)"), relPath: rel, size: 10, type: t, captureDate: Date())
        }
        let planned = PreservePlanner.plan([
            mf("A001.RDM/c.RDC/._clip.R3D", .junk),
            mf("A001.RDM/c.RDC/clip.R3D", .cinema),
            mf("PRIVATE/XDROOT/Clip/C0001.MXF", .cinema),
            mf("PRIVATE/M4ROOT/CLIP/C0001.MP4", .video),
        ])
        let byPath = Dictionary(uniqueKeysWithValues: planned.map { ($0.relPath, $0.preserve) })
        #expect(byPath["A001.RDM/c.RDC/._clip.R3D"] == false)
        #expect(byPath["A001.RDM/c.RDC/clip.R3D"] == true)
        #expect(byPath["PRIVATE/XDROOT/Clip/C0001.MXF"] == true)
        #expect(byPath["PRIVATE/M4ROOT/CLIP/C0001.MP4"] == false)
    }

    /// P1/P2: traversal via token vazio, `/` em rename.template, padding abusivo e delete(id: "../evil").
    @Test func validacoesDeTemplateEPresetStore() throws {
        #expect(throws: NamingError.self) {
            try NameBuilder.validateNoTraversal(in: "{projeto}/..{operador}/{tipo}")
        }
        var p = Preset.flatDefault
        p.rename.enabled = true
        p.rename.template = "sub/{nome_original}"
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(p) }

        var badPad = Preset.flatDefault
        badPad.rename.counterPadding = 999
        #expect(throws: PresetStore.PresetError.self) { try PresetStore.validate(badPad) }

        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(directory: dir)
        #expect(throws: PresetStore.PresetError.self) { try store.delete(id: "../fora") }
    }

    /// P0/P1: XXHash64 bypassCache igual ao normal e canSafelyFormatCard respeita manifestFailures e sidecar-only skip.
    @Test func hashBypassCacheEDecisaoSeguraDeFormatar() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sample.bin")
        let payload = Data("0123456789abcdef0123456789abcdef0123456789abcdef".utf8)
        try payload.write(to: file)
        let h1 = try XXHash64.hash(fileAt: file, bypassCache: false)
        let h2 = try XXHash64.hash(fileAt: file, bypassCache: true)
        #expect(h1 == h2)
        #expect(h1 == XXHash64.hash(payload))

        let onlySidecarSkipped = OffloadOutcome(verifiedCount: 0, failures: [], unrecognized: [],
                                                skipped: ["PRIVATE/M4ROOT/CLIP/C0001M01.XML"], skippedMediaCount: 0)
        #expect(!onlySidecarSkipped.canSafelyFormatCard)

        let failedManifest = OffloadOutcome(verifiedCount: 2, failures: [], unrecognized: [], skipped: [],
                                            manifestFailures: ["SSD"])
        #expect(!failedManifest.canSafelyFormatCard)
    }

    /// P1: CopyService recusa destino dentro do próprio cartão.
    @Test func copyServiceRecusaDestinoDentroDoCartao() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let nestedDest = card.root.appendingPathComponent("OUT")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        #expect(throws: OffloadError.self) {
            _ = try svc.run(cardRoot: card.root, chosenMedia: .both, destinations: [nestedDest], camera: "Cam")
        }
    }
}
