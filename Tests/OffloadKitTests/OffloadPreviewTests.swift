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

    @Test func previewOnlyVideoExcludesPhotos() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let service = CopyService(preset: .sampleConferencia, spaceProvider: Enough(), timeZone: .current)
        let p = try service.preview(cardRoot: card.root, chosenMedia: .video, destinations: [URL(fileURLWithPath: "/x")])
        #expect(p.photos == 0)
        #expect(p.videos == 1)
        #expect(p.selectedCount == 1)
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
