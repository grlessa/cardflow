import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit
import CardFormatKit

@MainActor @Suite struct AuditAppRegressionTests {
    private func vol(_ name: String, disk: String, uuid: String, removable: Bool = true) -> ExternalVolume {
        ExternalVolume(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, isRemovable: removable, isInternal: false,
                       totalBytes: 64_000_000_000, physicalDeviceID: disk, volumeUUID: uuid)
    }

    @Test func puxarCartaoEmConfirmingCancelaERemoveSessao() {
        let m = AppModel(formatter: FakeFormatter())
        let c1 = vol("CARD1", disk: "disk4", uuid: "U1")
        m.syncCards(with: [c1])
        let card = m.cards[0]
        card.formatState = .confirming(CardWipeReport())

        // Cartão é puxado com a folha de confirmação aberta: NÃO pode continuar em voo nem absorver outro cartão.
        m.syncCards(with: [])
        #expect(m.cards.isEmpty)
        #expect(card.formatState == .idle)

        let c2 = vol("CARD2", disk: "disk4", uuid: "U2")
        m.syncCards(with: [c2])
        #expect(m.cards.count == 1 && m.cards[0] !== card)
    }

    @Test func aposPrimeiraRemontagemDeDoneTirarSemEjetarDeixaCartaoSair() throws {
        let m = AppModel(formatter: FakeFormatter())
        m.syncCards(with: [vol("Untitled", disk: "disk4", uuid: "OLD")])
        let card = m.cards[0]
        card.scanned = []
        card.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: []))
        card.formatState = .done(try FormatPlan.make(totalSectors: 134_217_728, sectorSize: 512))
        card.formattedAt = Date()

        // 1ª remontagem pós-formatação: continua o mesmo cartão e atualiza o volume para o novo UUID.
        m.syncCards(with: [vol("Untitled", disk: "disk4", uuid: "NEW")])
        #expect(m.cards.count == 1 && m.cards[0] === card)
        #expect(card.volume.volumeUUID == "NEW")

        // Usuário ejeta pelo Finder (sem clicar no botão Ejetar do app) e insere outro cartão cheio:
        m.syncCards(with: [])
        #expect(m.cards.isEmpty)

        m.syncCards(with: [vol("CARD_CHEIO", disk: "disk4", uuid: "CHEIO")])
        #expect(m.cards.count == 1 && m.cards[0] !== card)
    }

    @Test func trocarPrincipalParaBackupNaoVoltaSozinhoParaPrincipal() {
        let m = AppModel(formatter: FakeFormatter())
        let ssd1 = vol("SSD1", disk: "disk5", uuid: "UUID-1", removable: false)
        let ssd2 = vol("SSD2", disk: "disk6", uuid: "UUID-2", removable: false)
        m.watcher.volumes = [ssd1, ssd2]
        m.forcedDestinations = [ssd1.id, ssd2.id]
        m.setUserDestination(ssd1.url)
        #expect(m.destinationURL == ssd1.url)

        // Troca SSD1 para papel de Backup: deve virar backup e não voltar para Principal.
        m.setRole(.backup, for: ssd1.url)
        #expect(m.backupURL == ssd1.url)
        #expect(m.destinationURL != ssd1.url)
    }

    @Test func pastaPersonalizadaComBarraFinalNaoDuplica() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-custom-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m = AppModel(formatter: FakeFormatter())
        m.customFolders = []
        let withSlash = URL(fileURLWithPath: dir.path + "/", isDirectory: true)
        let withoutSlash = URL(fileURLWithPath: dir.path, isDirectory: false)
        m.addDestinationFolder(withSlash)
        m.addDestinationFolder(withoutSlash)
        let matching = m.customFolders.filter { $0.path == dir.standardizedFileURL.path }
        #expect(matching.count == 1)
    }

    @Test func rascunhoDoModeloDeFabricaPreservadoAoReabrirInspetor() {
        let m = AppModel(formatter: FakeFormatter())
        m.reloadPresets()
        let ed1 = m.makeLiveEditor()
        ed1.draft.evento = "Evento Editado"
        m.applyLiveDraft(ed1)
        #expect(m.previewPresetOverride?.evento == "Evento Editado")

        // Fecha e reabre o inspetor: deve restaurar o rascunho em andamento, mantendo hasUnsavedChanges == true.
        let ed2 = m.makeLiveEditor()
        #expect(ed2.draft.evento == "Evento Editado")
        #expect(ed2.hasUnsavedChanges)
    }

    @Test func reverterEdicaoEmModeloSalvoAindaMarcaComoAlteradoAposSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cf-presets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PresetStore(directory: dir)
        var saved = Preset.flatDefault
        saved.id = "custom-1"
        saved.name = "Meu Modelo"
        saved.copySidecars = .skip
        try store.save(saved)

        let ed = PresetEditorModel.editing(saved)
        ed.draft.copySidecars = .aside
        #expect(ed.hasUnsavedChanges)
        #expect(ed.save(into: store))
        #expect(!ed.hasUnsavedChanges)

        // Reverte pro valor anterior (.skip): agora precisa detectar mudança para salvar a reversão!
        ed.draft.copySidecars = .skip
        #expect(ed.hasUnsavedChanges)
    }

    @Test func autoFormatWarningExigeFormatacaoDisponivelECamerasIncluidas() {
        let fake = FakeFormatter()
        fake.permission = .needsApproval
        let m = AppModel.withTestCard(formatter: fake)
        let c = m.cards[0]
        var pv = OffloadPreview(photos: 1, videos: 0, audios: 0, cinema: 0, junk: 0, selectedCount: 1, totalBytes: 100,
                                unrecognized: [], shortfalls: [])
        pv.excludedByChoice = [.video: 2]
        c.preview = pv
        m.autoFormatThisSession = true
        // Sem permissão de formatar -> sem aviso de formatação automática
        #expect(m.autoFormatWarning(c) == nil)
    }
}
