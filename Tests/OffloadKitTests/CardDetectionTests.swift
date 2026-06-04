import Testing
import Foundation
@testable import OffloadKit

@Suite struct CardDetectionTests {
    @Test func detectsCardByCameraStructure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vol = ExternalVolume(url: dir, name: "SONY", isRemovable: true, isInternal: false)
        #expect(CardDetection.isCard(vol) == true)
    }

    @Test func plainExternalDiskIsNotACard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vol = ExternalVolume(url: dir, name: "SSD", isRemovable: false, isInternal: false)
        #expect(CardDetection.isCard(vol) == false)
    }

    @Test func splitsCardsFromDestinations() throws {
        let cardDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cardDir.appendingPathComponent("PRIVATE"), withIntermediateDirectories: true)
        let ssdDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: ssdDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cardDir); try? FileManager.default.removeItem(at: ssdDir) }
        let card = ExternalVolume(url: cardDir, name: "CARD", isRemovable: true, isInternal: false)
        let ssd = ExternalVolume(url: ssdDir, name: "SSD", isRemovable: false, isInternal: false)
        #expect(CardDetection.cards(from: [card, ssd]) == [card])
        #expect(CardDetection.destinations(from: [card, ssd]) == [ssd])
    }

    // Regressão (bug real): cartão no leitor embutido reporta isInternal=true, mas é
    // removível e tem DCIM. Não pode ser excluído por "interno".
    @Test func detectsRemovableCardEvenWhenReportedInternal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vol = ExternalVolume(url: dir, name: "Untitled", isRemovable: true, isInternal: true)
        #expect(CardDetection.isCard(vol) == true)
        #expect(CardDetection.cards(from: [vol]) == [vol])
        #expect(CardDetection.destinations(from: [vol]).isEmpty)
    }

    // Regressão: volume de sistema (interno, NÃO removível) com /private NÃO é cartão.
    @Test func internalNonRemovableWithPrivateIsNotACard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("PRIVATE"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vol = ExternalVolume(url: dir, name: "Macintosh HD", isRemovable: false, isInternal: true)
        #expect(CardDetection.isCard(vol) == false)
    }

    private func cardWith(_ build: (URL) throws -> Void) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try build(dir)
        return CardDetection.isCard(ExternalVolume(url: dir, name: "X", isRemovable: true, isInternal: false))
    }

    // Cinema EOS (C70/C80) e P2: NÃO criam DCIM, usam CONTENTS — antes falhava, agora detecta.
    @Test func detectaCinemaEosPorContents() throws {
        #expect(try cardWith { try FileManager.default.createDirectory(at: $0.appendingPathComponent("CONTENTS/CLIPS001"), withIntermediateDirectories: true) } == true)
    }

    @Test(arguments: ["MP_ROOT", "CRM", "AVF_INFO"])
    func detectaMarcadoresFortes(marcador: String) throws {
        #expect(try cardWith { try FileManager.default.createDirectory(at: $0.appendingPathComponent(marcador), withIntermediateDirectories: true) } == true)
    }

    // AVCHD/XDCAM ficam SOB PRIVATE → o marcador PRIVATE detecta (não precisa de AVCHD/XDROOT soltos).
    @Test func detectaAvchdSobPrivate() throws {
        #expect(try cardWith { try FileManager.default.createDirectory(at: $0.appendingPathComponent("PRIVATE/AVCHD/BDMV"), withIntermediateDirectories: true) } == true)
    }

    // #4 (falso-positivo): destino com .mov/.jpg GENÉRICO solto na raiz NÃO vira fonte.
    @Test func destinoComMidiaGenericaSoltaNaoEhFonte() throws {
        #expect(try cardWith { FileManager.default.createFile(atPath: $0.appendingPathComponent("clip.mov").path, contents: Data()) } == false)
        #expect(try cardWith { FileManager.default.createFile(atPath: $0.appendingPathComponent("foto.jpg").path, contents: Data()) } == false)
    }

    // #6 (falso-positivo): CONTENTS sem pasta de clipe dentro NÃO é fonte.
    @Test func contentsSemClipeNaoEhFonte() throws {
        #expect(try cardWith { try FileManager.default.createDirectory(at: $0.appendingPathComponent("CONTENTS/MISC"), withIntermediateDirectories: true) } == false)
    }

    // RED: pastas com SUFIXO .RDM/.RDC (nome variável A001_C001.RDC) — detecção por sufixo.
    @Test func detectaRedPorSufixoRdmRdc() throws {
        #expect(try cardWith { try FileManager.default.createDirectory(at: $0.appendingPathComponent("A001_C001.RDM"), withIntermediateDirectories: true) } == true)
    }

    // Blackmagic: grava .braw solto na raiz, sem pasta-marcador.
    @Test func detectaBlackmagicPorBrawNaRaiz() throws {
        #expect(try cardWith { FileManager.default.createFile(atPath: $0.appendingPathComponent("A001_clip.braw").path, contents: Data()) } == true)
    }

    // Gravador de áudio (Lark M2): .wav solto na raiz, lixo do macOS ignorado → é fonte.
    @Test func detectaGravadorPorWavNaRaiz() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("20260522_2002.wav").path, contents: Data())
        } == true)
    }

    // NÃO-falso-positivo: destino com mídia em SUBPASTA (não solta na raiz) NÃO é fonte.
    @Test func destinoComMidiaEmSubpastaNaoEhFonte() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("Backup-2026"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("Backup-2026/video.mov").path, contents: Data())
        } == false)
    }

    // NÃO-falso-positivo: disco removível vazio (ou só com lixo do macOS) NÃO é fonte.
    @Test func discoVazioNaoEhFonte() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
        } == false)
    }
}
