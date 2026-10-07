import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit

@MainActor @Suite struct AppModelMultiCardTests {
    func tmp(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Pasta que parece cartão de câmera (DCIM com fotos).
    func cardDir(_ name: String, photos: Int = 3) throws -> ExternalVolume {
        let root = try tmp(name)
        let dcim = root.appendingPathComponent("DCIM/100MSDCF")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for i in 1...photos {
            try Data((0..<2048).map { UInt8(($0 + i + name.count) & 0xFF) }).write(to: dcim.appendingPathComponent("\(name)_\(i).JPG"))
        }
        return ExternalVolume(url: root, name: name, isRemovable: true, isInternal: false, totalBytes: 64_000_000_000,
                              physicalDeviceID: "disk-\(name)", volumeUUID: UUID().uuidString)
    }
    func destDir() throws -> ExternalVolume {
        ExternalVolume(url: try tmp("SSD"), name: "SSD", isRemovable: false, isInternal: false,
                       totalBytes: 2_000_000_000_000, physicalDeviceID: "disk-ssd", volumeUUID: UUID().uuidString)
    }
    func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<1000 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    func isReady(_ c: CardSession) -> Bool { c.phase == .ready && c.preview != nil }

    @Test func umaSessaoPorCartaoESomeQuandoSai() async throws {
        let a = try cardDir("A001"), b = try cardDir("B002")
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [a, b]; m.reconcileVolumes()
        #expect(m.cards.map(\.volume.name) == ["A001", "B002"])
        #expect(m.selectedCard?.volume.name == "A001")
        await waitUntil { m.cards.allSatisfy { $0.phase == .ready } }
        #expect(m.cards.allSatisfy { $0.scanned?.count == 3 })
        m.selection = .card(b.id)
        #expect(m.selectedCard?.volume.name == "B002")
        m.watcher.volumes = [b]; m.reconcileVolumes()
        #expect(m.cards.map(\.volume.name) == ["B002"])
    }

    @Test func trocarMidiaRecalculaSemReler() async throws {
        let a = try cardDir("A001"), d = try destDir()
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [a, d]; m.reconcileVolumes()
        let card = try #require(m.cards.first)
        await waitUntil { isReady(card) }
        let scanned = card.scanned
        m.setMediaChoice(.video, for: card)
        await waitUntil { card.preview?.photos == 0 && card.preview?.selectedCount == 0 }
        #expect(card.preview?.selectedCount == 0)
        #expect(card.scanned == scanned)   // a lista do cartão não foi relida
    }

    @Test func filaCopiaOsDoisCartoesUmDepoisDoOutro() async throws {
        let a = try cardDir("A001"), b = try cardDir("B002"), d = try destDir()
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [a, b, d]; m.reconcileVolumes()
        #expect(m.destinationURL == d.url)
        await waitUntil { m.cards.allSatisfy(isReady) }
        #expect(m.readyToCopyCount == 2)
        m.enqueueAll()
        #expect(m.cards.contains { $0.phase == .queued })   // o 2º espera a vez
        await waitUntil { m.cards.allSatisfy { if case .finished = $0.phase { return true }; return false } }
        for c in m.cards {
            guard case .finished(let o) = c.phase else { Issue.record("não terminou: \(c.volume.name)"); continue }
            #expect(o.verifiedCount == 3 && o.failures.isEmpty)
        }
        await waitUntil { m.history.items.count == 2 }
        #expect(m.history.items.count == 2)
        // o projeto tem um relatório só com os dois cartões
        let report = d.url.appendingPathComponent(m.effectiveEvento).appendingPathComponent(ProjectReport.fileName(locale: AppLocale.effective))
        let html = try String(contentsOf: report, encoding: .utf8)
        #expect(html.contains("A001") && html.contains("B002"))
    }

    @Test func cartaoQueSaiDepoisDeCopiadoViraRecente() async throws {
        let a = try cardDir("A001"), d = try destDir()
        let m = AppModel(formatter: FakeFormatter())
        m.watcher.volumes = [a, d]; m.reconcileVolumes()
        let card = try #require(m.cards.first)
        m.selection = .card(card.id)
        await waitUntil { isReady(card) }
        m.enqueueCopy(card)
        await waitUntil { if case .finished = card.phase { return true }; return false }
        m.watcher.volumes = [d]; m.reconcileVolumes()
        #expect(m.cards.isEmpty)
        guard case .recent(let id)? = m.selection else { Issue.record("seleção não foi pra Recentes"); return }
        await waitUntil { m.history.item(id) != nil }
        #expect(m.history.item(id)?.title == "A001")
    }
}
