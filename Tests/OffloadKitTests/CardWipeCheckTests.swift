import Testing
import Foundation
@testable import OffloadKit

@Suite struct CardWipeCheckTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func put(_ card: URL, _ rel: String, _ content: String) throws {
        let u = card.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: u)
    }
    var preset: Preset {
        var p = Preset.flatDefault; p.evento = "EV"
        p.sidecarExtensions = ["xml"]; p.copySidecars = .skip
        return p
    }
    func copy(_ card: URL, _ media: Preset.Media.Kind, _ dests: [URL]) throws {
        _ = try CopyService(preset: preset, spaceProvider: WipeTestSpace(), timeZone: .current)
            .run(cardRoot: card, chosenMedia: media, destinations: dests, camera: "Cam")
    }
    func check(_ card: URL, _ media: Preset.Media.Kind, _ dests: [URL]) throws -> CardWipeReport {
        try CardWipeCheck.evaluate(cardRoot: card, preset: preset,
                                   choices: WipeChoices(chosenMedia: media, capturedIn: nil), destinations: dests)
    }

    @Test func tudoCopiadoPodeApagar() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD"), dest = w.appendingPathComponent("SSD")
        try put(card, "DCIM/100/A.JPG", "foto"); try put(card, "DCIM/100/C1.MP4", "video")
        try put(card, ".DS_Store", "lixo")
        try copy(card, .both, [dest])
        let r = try check(card, .both, [dest])
        #expect(r.saved == 2 && r.junk == 1 && r.notVerified.isEmpty && r.excludedTotal == 0 && r.canWipe)
    }

    @Test func midiaDeixadaPorEscolhaNaoBloqueiaMasEhContada() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD"), dest = w.appendingPathComponent("SSD")
        try put(card, "DCIM/100/A.JPG", "foto"); try put(card, "DCIM/100/B.JPG", "foto2"); try put(card, "DCIM/100/C1.MP4", "video")
        try put(card, "DCIM/100/C1M01.XML", "<x/>")
        try copy(card, .video, [dest])
        let r = try check(card, .video, [dest])
        #expect(r.canWipe, "\(r)")
        #expect(r.excludedByChoice[.photo] == 2 && r.excludedByChoice[.sidecar] == 1)
    }

    @Test func arquivoNovoDepoisDaCopiaBloqueia() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD"), dest = w.appendingPathComponent("SSD")
        try put(card, "DCIM/100/C1.MP4", "video")
        try copy(card, .both, [dest])
        try put(card, "DCIM/100/C2.MP4", "novo")
        let r = try check(card, .both, [dest])
        #expect(!r.canWipe && r.notVerified == ["DCIM/100/C2.MP4"])
    }

    @Test func arquivoAlteradoMesmoTamanhoOutraDataBloqueia() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD"), dest = w.appendingPathComponent("SSD")
        try put(card, "DCIM/100/C1.MP4", "video-a")
        try copy(card, .both, [dest])
        let f = card.appendingPathComponent("DCIM/100/C1.MP4")
        try Data("video-b".utf8).write(to: f)
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.creationDate: later, .modificationDate: later], ofItemAtPath: f.path)
        let r = try check(card, .both, [dest])
        #expect(r.notVerified == ["DCIM/100/C1.MP4"])
    }

    @Test func faltandoNumDosDestinosBloqueia() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD"), a = w.appendingPathComponent("SSD"), b = w.appendingPathComponent("HD")
        try put(card, "DCIM/100/C1.MP4", "video")
        try copy(card, .both, [a, b])
        try FileManager.default.removeItem(at: b.appendingPathComponent("EV"))
        let r = try check(card, .both, [a, b])
        #expect(!r.canWipe)
    }

    @Test func previaContaOQueFicaDeFora() throws {
        let w = try tempDir(); defer { try? FileManager.default.removeItem(at: w) }
        let card = w.appendingPathComponent("CARD")
        try put(card, "DCIM/100/A.JPG", "foto"); try put(card, "DCIM/100/C1.MP4", "video")
        let pv = try CopyService(preset: preset, spaceProvider: WipeTestSpace(), timeZone: .current)
            .preview(cardRoot: card, chosenMedia: .video, destinations: [w.appendingPathComponent("SSD")])
        #expect(pv.excludedByChoice[.photo] == 1 && pv.excludedByChoice[.video] == nil)
    }
}

private struct WipeTestSpace: FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64 { Int64.max }
}
