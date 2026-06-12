import Testing
import Foundation
@testable import OffloadKit

@Suite struct OffloadPreviewTests {
    private struct Enough: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { .max } }
    private struct Tiny: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { 1 } }

    @Test func previewCountsSelectedMediaAndTotals() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(), timeZone: .current)
        let dest = URL(fileURLWithPath: "/Volumes/SSD")
        let p = try service.preview(cardRoot: card.root, chosenMedia: .both, destinations: [dest])
        #expect(p.photos == 2)
        #expect(p.videos == 1)
        #expect(p.selectedCount == 3)
        // 3 mídias + o não-reconhecido (64 B), que agora é copiado como rede de segurança (#3)
        #expect(p.totalBytes == 2048 + 1024 + 4096 + 64)
        #expect(p.unrecognized == ["MISC/notas.txt"])
        #expect(p.shortfalls.isEmpty)
    }

    @Test func previewReportsShortfall() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Tiny(), timeZone: .current)
        let dest = URL(fileURLWithPath: "/Volumes/TINY")
        let p = try service.preview(cardRoot: card.root, chosenMedia: .both, destinations: [dest])
        #expect(p.shortfalls.count == 1)
        #expect(p.shortfalls.first?.destination == dest)
    }

    @Test func previewIgnoraThumbnailDeVideoEContaComoLixo() throws {
        let card = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: card) }
        let fm = FileManager.default
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL"), withIntermediateDirectories: true)
        // 1 foto real no DCIM (protegida pela localização) + 2 thumbnails no THMBNL (lixo por pasta)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG").path, contents: Data(count: 5000))
        fm.createFile(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL/LF_0001T01.JPG").path, contents: Data(count: 90_000))
        fm.createFile(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL/LF_0002T01.JPG").path, contents: Data(count: 90_000))

        let service = CopyService(preset: .factoryDefault, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: card, chosenMedia: .both, destinations: [URL(fileURLWithPath: "/x")])
        #expect(p.photos == 1)   // só a foto real do DCIM conta
        #expect(p.junk == 2)     // as 2 thumbnails viram lixo (transparência)
    }

    @Test func previewListaArquivosIgnoradosComoLixo() throws {
        let card = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: card) }
        let fm = FileManager.default
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG").path, contents: Data(count: 5000))
        fm.createFile(atPath: card.appendingPathComponent(".DS_Store").path, contents: Data(count: 10))
        fm.createFile(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/THMBNL/LF_0001T01.JPG").path, contents: Data(count: 90_000))

        let service = CopyService(preset: .factoryDefault, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: card, chosenMedia: .both, destinations: [URL(fileURLWithPath: "/x")])

        #expect(p.junk == 2)
        #expect(p.junkPaths == [
            ".DS_Store",
            "PRIVATE/M4ROOT/THMBNL/LF_0001T01.JPG"
        ])
    }

    @Test func previewOnlyVideoExcludesPhotos() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: card.root, chosenMedia: .video, destinations: [URL(fileURLWithPath: "/x")])
        #expect(p.photos == 0)
        #expect(p.videos == 1)
        #expect(p.selectedCount == 1)
    }

    @Test func previewMarksAlreadyPresentFromInterruptedManifest() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pv-interrupted-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let preset = Preset.sampleConferencia
        let eventName = NameBuilder.sanitizePathComponent(preset.evento)
        let manifest = Manifest(
            schemaVersion: 2,
            offloadId: "partial",
            appVersion: "test",
            presetName: preset.name,
            camera: "Cam01",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            source: .init(volumeName: "CARD", fingerprint: "fp", fileCount: 2, bytes: 3_072),
            destinations: [dest.path],
            files: [
                .init(sourceRelPath: "DCIM/100MSDCF/DSC00001.JPG", destRelPath: "x/1.JPG", type: .photo, bytes: 2_048, xxhash64: "1", status: "verified"),
                .init(sourceRelPath: "DCIM/100MSDCF/DSC00002.JPG", destRelPath: "x/2.JPG", type: .photo, bytes: 1_024, xxhash64: "2", status: "verified")
            ],
            unrecognized: [],
            totals: .init(photos: 2, videos: 0, audio: 0, sidecars: 0, verified: 2, failed: 0, skipped: 0),
            interrupted: true)
        try ManifestStore().write(manifest, eventRootIn: dest, eventName: eventName)

        let service = CopyService(preset: preset, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: card.root, chosenMedia: .both, destinations: [dest])

        #expect(p.alreadyPresent == 2)
        #expect(p.alreadyPresentFromInterrupted == 2)
    }

    @Test func previewContaPacotesDeCinemaSeparado() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-cine-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ rel: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        defer { try? fm.removeItem(at: root) }
        try write("DCIM/100/DSC.JPG")                              // 1 foto
        try write("A001.RDM/c.RDC/a_001.R3D")                      // bundle 1
        try write("A001.RDM/c.RDC/a_002.R3D")                      // mesmo bundle
        try write("clip.braw"); try write("clip.sidecar")         // bundle 2
        let service = CopyService(preset: .factoryDefault, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: root, chosenMedia: .both, destinations: [URL(fileURLWithPath: "/x")])
        #expect(p.cinema == 2)      // A001.RDM + clip = 2 pacotes (não 3 arquivos)
        #expect(p.photos == 1)
        #expect(p.videos == 0)      // cinema não conta como vídeo
    }

    // REPRO do bug do usuário: cartão grande (foto pequena + vídeo grande), disco que cabe a foto
    // mas não o total. No modo "só fotos", NÃO pode acusar falta de espaço — o vídeo está fora.
    @Test func previewSoFotosNaoAcusaFaltaDeEspacoSeFotosCabem() throws {
        let card = FileManager.default.temporaryDirectory.appendingPathComponent("pv-space-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/IMG.JPG").path, contents: Data(count: 100))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/CLIP.MP4").path, contents: Data(count: 10_000))
        defer { try? fm.removeItem(at: card) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pv-dest-" + UUID().uuidString)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dest) }
        struct Fixed: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { 1000 } }
        let service = CopyService(preset: .factoryDefault, spaceProvider: Fixed(), timeZone: .current, marginBytes: 0)

        let soFotos = try service.preview(cardRoot: card, chosenMedia: .photo, destinations: [dest])
        #expect(soFotos.photos == 1)
        #expect(soFotos.videos == 0)            // vídeo fora da seleção
        #expect(soFotos.totalBytes == 100)      // espaço pedido = só a foto
        #expect(soFotos.shortfalls.isEmpty)     // 100 < 1000 → cabe, NÃO bloqueia

        let tudo = try service.preview(cardRoot: card, chosenMedia: .both, destinations: [dest])
        #expect(tudo.totalBytes == 10_100)      // foto + vídeo
        #expect(tudo.shortfalls.count == 1)     // 10_100 > 1000 → aí sim falta espaço
    }

    @Test func previewFotoSozinhaZeraCinema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-cine2-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("A001.RDM/c.RDC"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("A001.RDM/c.RDC/a.R3D"))
        defer { try? fm.removeItem(at: root) }
        let service = CopyService(preset: .factoryDefault, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: root, chosenMedia: .photo, destinations: [URL(fileURLWithPath: "/x")])
        #expect(p.cinema == 0)   // não selecionado → não conta (igual aos outros tipos)
    }
}
