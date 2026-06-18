import Testing
import Foundation
@testable import OffloadKit

@Suite struct CardDetectionTests {
    @Test func internalShortcutFlagDefaultsFalseAndCanBeSet() {
        let normal = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/SSD"), name: "SSD",
                                    isRemovable: true, isInternal: false)
        #expect(normal.isInternalShortcut == false)
        let atalho = ExternalVolume(url: URL(fileURLWithPath: "/Users/x/Documents"), name: "Documentos",
                                    isRemovable: false, isInternal: true, isInternalShortcut: true)
        #expect(atalho.isInternalShortcut == true)
    }

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

    // SSD externo fixo (monta como NÃO removível, mas é externo) com clipe de cinema na raiz É fonte.
    // Destrava o caso do vídeo: câmera que grava em SSD via USB-C/Thunderbolt.
    @Test func ssdExternoFixoComCinemaEhFonte() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("A001_clip.braw").path, contents: Data())
        let ssd = ExternalVolume(url: dir, name: "SAMSUNG T7", isRemovable: false, isInternal: false)
        #expect(CardDetection.isCard(ssd) == true)
    }

    // Cinema organizado em SUBPASTA (SSD/Reel01/A001.braw) é fonte — recursão por estrutura.
    @Test func detectaCinemaEmSubpasta() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("Reel01"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("Reel01/A001.braw").path, contents: Data())
        } == true)
    }

    @Test func detectaCinemaEmSubpastaDoisNiveis() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("2026/Reel01"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("2026/Reel01/A001.r3d").path, contents: Data())
        } == true)
    }

    // Time Machine NUNCA é fonte, mesmo com clipe de cinema raso (não varrer footage de backup).
    @Test func timeMachineNaoEhFonte() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Backups.backupdb"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("A001.braw").path, contents: Data())
        let tm = ExternalVolume(url: dir, name: "Time Machine", isRemovable: false, isInternal: false)
        #expect(CardDetection.isCard(tm) == false)
    }

    // Clipe fundo demais (> 2 níveis de subpasta) NÃO dispara a recursão — limita I/O e evita backup.
    @Test func cinemaFundoDemaisNaoEhFonte() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("a/b/c/d"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("a/b/c/d/A001.braw").path, contents: Data())
        } == false)
    }

    // APFS Time Machine (Ventura+) usa .sparsebundle na raiz, não Backups.backupdb — também excluído.
    @Test func apfsTimeMachineNaoEhFonte() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("MacBook.sparsebundle"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("A001.braw").path, contents: Data())
        let tm = ExternalVolume(url: dir, name: "Time Machine", isRemovable: false, isInternal: false)
        #expect(CardDetection.isCard(tm) == false)
    }

    // TRADEOFF CONHECIDO (não "corrigir" sem rever a decisão): disco com clipe de cinema RASO em
    // subpasta (Projetos/FilmeX/A001.braw) vira fonte. É o preço da detecção "conservadora por
    // estrutura" — é assim que se pega o SSD de cinema organizado em pastas.
    @Test func discoComCinemaRasoEhFonteTradeoffConhecido() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("Projetos/FilmeX"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("Projetos/FilmeX/A001.braw").path, contents: Data())
        } == true)
    }

    // O destino de offload REAL tem a footage 3+ níveis fundo (evento/dia/tipo/clip), FORA do alcance da
    // recursão — então um disco de destino de sessões anteriores NÃO é re-detectado como fonte.
    @Test func destinoDeOffloadComFootageProfundaNaoEhFonte() throws {
        #expect(try cardWith {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("Sessao/28 Mai 2026/Cinema"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: $0.appendingPathComponent("Sessao/28 Mai 2026/Cinema/A001.braw").path, contents: Data())
        } == false)
    }
}
