import Testing
import Foundation
@testable import OffloadKit

@Suite struct CopyServiceTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func copiesSelectedMediaVerifiedToAllDestinations() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest1 = work.appendingPathComponent("SSD")
        let dest2 = work.appendingPathComponent("HD")

        let service = CopyService(preset: .sampleConferencia,
                                  spaceProvider: AlwaysEnoughSpace(),
                                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let outcome = try service.run(
            cardRoot: card.root, chosenMedia: .both,
            destinations: [dest1, dest2], camera: "Cam01"
        )

        // 2 fotos + 1 vídeo = 3 mídias, verificadas em 2 destinos → 6 verificações.
        #expect(outcome.verifiedCount == 6)
        #expect(outcome.failures.isEmpty)
        // O .txt desconhecido entra na rede de segurança; o sidecar e o lixo NÃO alertam.
        #expect(outcome.unrecognized == ["MISC/notas.txt"])

        // Confere fisicamente um arquivo no destino 1.
        let foto = dest1.appendingPathComponent("Conferencia-Junho-2026/Foto/DSC00001.JPG")
        #expect(FileManager.default.fileExists(atPath: foto.path))
    }

    @Test func copiaAudioQuandoEscolhidoEPulaQuandoNao() throws {
        let card = try tempDir(); defer { try? FileManager.default.removeItem(at: card) }
        try FileManager.default.createDirectory(at: card.appendingPathComponent("PRIVATE/SOUND"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: card.appendingPathComponent("PRIVATE/SOUND/REC001.WAV").path,
                                       contents: Data("riff-fake-audio".utf8))
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }

        let service = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        // escolhendo Áudio: o .wav é copiado e verificado pra <evento>/Audio/
        let dest = work.appendingPathComponent("SSD")
        let comAudio = try service.run(cardRoot: card, chosenMedia: .audio, destinations: [dest], camera: "Cam01")
        #expect(comAudio.verifiedCount == 1)
        #expect(comAudio.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Offload/Audio/REC001.WAV").path))

        // escolhendo Foto: o áudio NÃO entra (nem como não-reconhecido — é áudio, só não foi pedido)
        let dest2 = work.appendingPathComponent("SSD2")
        let soFoto = try service.run(cardRoot: card, chosenMedia: .photo, destinations: [dest2], camera: "Cam01")
        #expect(soFoto.verifiedCount == 0)
        #expect(soFoto.unrecognized.isEmpty)
    }

    @Test func blocksWhenADestinationIsTooSmall() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("TINY")

        let service = CopyService(preset: .sampleConferencia,
                                  spaceProvider: FixedSpace(bytes: 1), // 1 byte livre
                                  timeZone: .current)
        #expect(throws: OffloadError.self) {
            _ = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        }
    }

    @Test func doesNotOverwritePreexistingDifferentContent() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let target = dest.appendingPathComponent("Conferencia-Junho-2026/Foto/DSC00001.JPG")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let precious = Data("PRECIOUS-DO-NOT-OVERWRITE".utf8)
        try precious.write(to: target)

        let service = CopyService(preset: .sampleConferencia, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")

        // o arquivo pre-existente continua INTACTO
        #expect(try Data(contentsOf: target) == precious)
        // e a midia da origem foi gravada sob nome desambiguado (existe outro DSC00001*.JPG)
        let fotoDir = dest.appendingPathComponent("Conferencia-Junho-2026/FOTO")
        let entries = try FileManager.default.contentsOfDirectory(atPath: fotoDir.path)
        let dsc1 = entries.filter { $0.hasPrefix("DSC00001") && $0.uppercased().hasSuffix(".JPG") }
        #expect(dsc1.count == 2)
    }

    @Test func secondRunSkipsAlreadyPresent() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let service = CopyService(preset: .sampleConferencia, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let first = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        #expect(first.verifiedCount == 3)
        #expect(first.skipped.isEmpty)
        let second = try service.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        #expect(second.verifiedCount == 0)
        #expect(Set(second.skipped) == Set([
            "DCIM/100MSDCF/DSC00001.JPG",
            "DCIM/100MSDCF/DSC00002.JPG",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML",   // sidecar-aside já presente agora também conta como pulado
            "MISC/notas.txt",                     // não-reconhecido (rede de segurança #3) já presente → pulado
        ]))
    }

    /// Helper: cartão com 1 foto plana + 1 bundle RED + grupo braw solto.
    private func cineCard() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cine-" + UUID().uuidString)
        let fm = FileManager.default
        func write(_ rel: String, _ s: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(s.utf8).write(to: u)
        }
        try write("DCIM/100MSDCF/DSC0001.JPG", "foto")
        try write("A001.RDM/A001_C001.RDC/A001_C001_001.R3D", "red-1")
        try write("A001.RDM/A001_C001.RDC/A001_C001.RMD", "red-meta")
        try write("clip.braw", "braw"); try write("clip.sidecar", "sc")
        try write("A001.RDM/A001_C001.RDC/.DS_Store", "junk")   // system junk dentro do bundle
        return root
    }

    @Test func preservaCinemaVerbatimEAchataFoto() throws {
        let card = try cineCard(); defer { try? FileManager.default.removeItem(at: card) }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let service = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let outcome = try service.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")

        let fm = FileManager.default
        let cardName = card.lastPathComponent
        // cinema: verbatim em {evento}/<cartão>/<relPath>, nome e estrutura intactos
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/\(cardName)/A001.RDM/A001_C001.RDC/A001_C001_001.R3D").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/\(cardName)/A001.RDM/A001_C001.RDC/A001_C001.RMD").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/\(cardName)/clip.braw").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/\(cardName)/clip.sidecar").path))
        // .DS_Store dentro do bundle NÃO é copiado
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Offload/\(cardName)/A001.RDM/A001_C001.RDC/.DS_Store").path))
        // foto: achatada em {evento}/Foto/
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/Foto/DSC0001.JPG").path))
        // 4 preservados (R3D, RMD, braw, sidecar) + 1 foto = 5 verificações num destino
        #expect(outcome.verifiedCount == 5)
        #expect(outcome.failures.isEmpty)
        // cinema não é "não-reconhecido" mesmo com RMD type unknown
        #expect(outcome.unrecognized.isEmpty)
    }

    @Test func segundaRodadaPulaPreservados() throws {
        let card = try cineCard(); defer { try? FileManager.default.removeItem(at: card) }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let service = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try service.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        let second = try service.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(second.verifiedCount == 0)   // tudo já presente, inclusive cinema
        #expect(second.skipped.contains("A001.RDM/A001_C001.RDC/A001_C001_001.R3D"))
    }

    private func writeFile(_ root: URL, _ rel: String, _ s: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: u)
    }

    @Test func cinemaCollisionRelocatesBundleKeepingNames() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)

        let card1 = work.appendingPathComponent("m1/A001")
        try writeFile(card1, "A001.RDM/c.RDC/clip_001.R3D", "RED-CARD-1")
        try writeFile(card1, "A001.RDM/c.RDC/clip_002.R3D", "RED-CARD-1-seg2")
        let o1 = try svc.run(cardRoot: card1, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(o1.relocatedCinema.isEmpty)

        let card2 = work.appendingPathComponent("m2/A001")   // mesmo nome, conteúdo diferente
        try writeFile(card2, "A001.RDM/c.RDC/clip_001.R3D", "RED-CARD-2-DIFFERENT")
        try writeFile(card2, "A001.RDM/c.RDC/clip_002.R3D", "RED-CARD-2-DIFFERENT-seg2")
        let o2 = try svc.run(cardRoot: card2, chosenMedia: .both, destinations: [dest], camera: "Cam")

        let fm = FileManager.default
        #expect(try Data(contentsOf: dest.appendingPathComponent("Offload/A001/A001.RDM/c.RDC/clip_001.R3D")) == Data("RED-CARD-1".utf8))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/A001 (2)/A001.RDM/c.RDC/clip_001.R3D").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/A001 (2)/A001.RDM/c.RDC/clip_002.R3D").path))
        #expect(try Data(contentsOf: dest.appendingPathComponent("Offload/A001 (2)/A001.RDM/c.RDC/clip_001.R3D")) == Data("RED-CARD-2-DIFFERENT".utf8))
        #expect(o2.relocatedCinema == ["A001.RDM"])
    }

    @Test func cinemaSameCardRerunDoesNotRelocate() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let card = work.appendingPathComponent("m/A001")
        try writeFile(card, "A001.RDM/c.RDC/clip_001.R3D", "RED")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        let o2 = try svc.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(o2.relocatedCinema.isEmpty)
        #expect(o2.verifiedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Offload/A001 (2)").path))
    }

    @Test func cinemaMixedOnlyCollidingBundleRelocates() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let card1 = work.appendingPathComponent("m1/CARD")
        try writeFile(card1, "A001.RDM/c.RDC/a.R3D", "A-shared")
        try writeFile(card1, "B002.RDM/c.RDC/b.R3D", "B-card1")
        _ = try svc.run(cardRoot: card1, chosenMedia: .both, destinations: [dest], camera: "Cam")
        let card2 = work.appendingPathComponent("m2/CARD")
        try writeFile(card2, "A001.RDM/c.RDC/a.R3D", "A-shared")
        try writeFile(card2, "B002.RDM/c.RDC/b.R3D", "B-card2-DIFFERENT")
        let o2 = try svc.run(cardRoot: card2, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(o2.relocatedCinema == ["B002.RDM"])
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Offload/CARD (2)/A001.RDM/c.RDC/a.R3D").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/CARD (2)/B002.RDM/c.RDC/b.R3D").path))
    }

    @Test func cinemaCollisionUsesSameParentOnAllDestinations() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let d1 = work.appendingPathComponent("SSD"); let d2 = work.appendingPathComponent("HD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let card1 = work.appendingPathComponent("m1/A001")
        try writeFile(card1, "A001.RDM/c.RDC/x.R3D", "one")
        _ = try svc.run(cardRoot: card1, chosenMedia: .both, destinations: [d1, d2], camera: "Cam")
        try FileManager.default.removeItem(at: d2.appendingPathComponent("Offload/A001/A001.RDM/c.RDC/x.R3D"))
        let card2 = work.appendingPathComponent("m2/A001")
        try writeFile(card2, "A001.RDM/c.RDC/x.R3D", "two-different")
        let o2 = try svc.run(cardRoot: card2, chosenMedia: .both, destinations: [d1, d2], camera: "Cam")
        #expect(o2.relocatedCinema == ["A001.RDM"])
        #expect(FileManager.default.fileExists(atPath: d1.appendingPathComponent("Offload/A001 (2)/A001.RDM/c.RDC/x.R3D").path))
        #expect(FileManager.default.fileExists(atPath: d2.appendingPathComponent("Offload/A001 (2)/A001.RDM/c.RDC/x.R3D").path))
    }

    @Test func looseBrawGroupRelocatesTogether() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let card1 = work.appendingPathComponent("m1/BMD")
        try writeFile(card1, "clip.braw", "v1"); try writeFile(card1, "clip.sidecar", "s1")
        _ = try svc.run(cardRoot: card1, chosenMedia: .both, destinations: [dest], camera: "Cam")
        let card2 = work.appendingPathComponent("m2/BMD")
        try writeFile(card2, "clip.braw", "v2-DIFFERENT"); try writeFile(card2, "clip.sidecar", "s2")
        let o2 = try svc.run(cardRoot: card2, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(o2.relocatedCinema == ["clip"])
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/BMD (2)/clip.braw").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/BMD (2)/clip.sidecar").path))
    }

    @Test func fotoSozinhaExcluiBundleDeCinema() throws {
        let card = try cineCard(); defer { try? FileManager.default.removeItem(at: card) }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let service = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let outcome = try service.run(cardRoot: card, chosenMedia: .photo, destinations: [dest], camera: "Cam")
        #expect(outcome.verifiedCount == 1)   // só a foto
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Offload/\(card.lastPathComponent)/clip.braw").path))
    }

    // Regressão do caminho rápido: dois arquivos de MESMO nome em pastas diferentes do
    // cartão (rollover), numa única rodada — o 1º usa o caminho rápido, o 2º o de colisão.
    // Nenhum pode sobrescrever o outro.
    @Test func intraCardSameNameDifferentFoldersBothPreserved() throws {
        let card = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/B"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: card) }
        try Data("conteudo-A".utf8).write(to: card.appendingPathComponent("DCIM/A/DSC00001.JPG"))
        try Data("conteudo-B-diferente".utf8).write(to: card.appendingPathComponent("DCIM/B/DSC00001.JPG"))
        let dest = try tempDir(); defer { try? FileManager.default.removeItem(at: dest) }

        let service = CopyService(preset: .sampleConferencia, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let outcome = try service.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")

        #expect(outcome.failures.isEmpty)
        #expect(outcome.verifiedCount == 2)
        let fotoDir = dest.appendingPathComponent("Conferencia-Junho-2026/FOTO")
        let names = try FileManager.default.contentsOfDirectory(atPath: fotoDir.path).filter { $0.hasPrefix("DSC00001") }
        #expect(names.count == 2)
        let contents = Set(try names.map { try Data(contentsOf: fotoDir.appendingPathComponent($0)) })
        #expect(contents == Set([Data("conteudo-A".utf8), Data("conteudo-B-diferente".utf8)]))
    }

    @Test func manifestWriteFailureIsSurfacedNotSwallowed() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        // cartão SÓ com uma foto (sem sidecar — o sidecar-aside também escreveria sob .cardflow)
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/DSC1.JPG").path, contents: Data("foto".utf8))
        // bloqueia o manifesto: ARQUIVO onde .cardflow seria a pasta → createDirectory falha
        let dest = work.appendingPathComponent("SSD")
        let offloadDir = dest.appendingPathComponent("Offload")
        try fm.createDirectory(at: offloadDir, withIntermediateDirectories: true)
        fm.createFile(atPath: offloadDir.appendingPathComponent(".cardflow").path, contents: Data())

        let service = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let outcome = try service.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        #expect(outcome.verifiedCount == 1)              // a foto copiou+verificou (mídia ok)
        #expect(outcome.manifestFailures == ["SSD"])     // manifesto falhou e foi SINALIZADO (não engolido)
        #expect(outcome.manifestPaths.isEmpty)
    }

    @Test func contadorEstavelEntreSelecoesDeMidia() throws {
        // vídeo (AAA) ordena ANTES da foto (BBB); com {contador} a foto pega o nº 2. Re-rodar só-foto
        // não pode renumerar a foto pra 1 (senão duplica). Contador estável → mesmo nome → pulada.
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/AAA.MP4").path, contents: Data("video".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/BBB.JPG").path, contents: Data("foto".utf8))
        var preset = Preset.flatDefault
        preset.rename = .init(enabled: true, template: "{evento}_{contador}_{nome_original}", counterPadding: 3)
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: preset, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card, chosenMedia: .both, destinations: [dest], camera: "Cam")
        let o2 = try svc.run(cardRoot: card, chosenMedia: .photo, destinations: [dest], camera: "Cam")
        #expect(o2.verifiedCount == 0)                       // foto já presente com o MESMO nome → pulada
        #expect(o2.skipped.contains("DCIM/100/BBB.JPG"))
        let fotoDir = dest.appendingPathComponent("Offload/FOTO")
        let jpgs = ((try? fm.contentsOfDirectory(atPath: fotoDir.path)) ?? []).filter { $0.uppercased().hasSuffix(".JPG") }
        #expect(jpgs.count == 1)                             // sem duplicata
    }

    // Defesa de ponta a ponta: mesmo um preset malicioso (CopyService.init NÃO chama validate)
    // não pode gravar NADA fora da pasta de destino — a guarda de contenção lança antes de copiar.
    @Test func refusesToWriteOutsideDestination() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/IMG.JPG").path, contents: Data("jpeg".utf8))
        let dest = work.appendingPathComponent("SSD")

        var p = Preset.flatDefault
        p.folderStructure = "../ESCAPED/{tipo}"   // tenta subir um nível, saindo de dest
        let service = CopyService(preset: p, spaceProvider: AlwaysEnoughSpace(),
                                  timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        #expect(throws: OffloadError.self) {
            _ = try service.run(cardRoot: card, chosenMedia: .photo, destinations: [dest], camera: "Cam01")
        }
        // e NADA foi gravado fora do destino
        #expect(!fm.fileExists(atPath: work.appendingPathComponent("ESCAPED").path))
    }

    // Pipeline de verificação paralela sob carga: 12 arquivos × 2 destinos = 24 conferências
    // rodando concorrentes com as cópias. Tudo precisa ser conferido, presente e correto.
    // Destino interno exige folga de 5GB; um disco com 1GB livre cabe a foto (margem externa 100MB)
    // mas NÃO satisfaz a reserva interna de 5GB → shortfall só quando o destino é interno.
    @Test func internalDestinationRequiresFiveGigReserve() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/IMG.JPG").path, contents: Data(count: 100))
        let dest = work.appendingPathComponent("DEST")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        struct OneGig: FreeSpaceProviding { func availableBytes(at url: URL) throws -> Int64 { 1_000_000_000 } }
        let svc = CopyService(preset: .factoryDefault, spaceProvider: OneGig(), timeZone: .current)

        let externo = try svc.preview(cardRoot: card, chosenMedia: .photo, destinations: [dest])
        #expect(externo.shortfalls.isEmpty)   // margem 100MB: foto cabe em 1GB

        let interno = try svc.preview(cardRoot: card, chosenMedia: .photo, destinations: [dest],
                                      internalDestinations: [dest])
        #expect(interno.shortfalls.count == 1)   // reserva 5GB não cabe em 1GB → bloqueia
    }

    // Dois cartões de conteúdo disjunto (formatado entre eles) caem em Lote 01 e Lote 02; o mesmo
    // cartão re-rodado continua no mesmo lote.
    @Test func doisCartoesDisjuntosCaemEmLotesSeparados() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let dest = work.appendingPathComponent("DEST")
        func card(_ name: String, _ clip: String) throws -> URL {
            let c = work.appendingPathComponent(name)
            try fm.createDirectory(at: c.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
            fm.createFile(atPath: c.appendingPathComponent("DCIM/100/\(clip).MP4").path,
                          contents: Data("\(clip)".utf8) + Data(count: 2000))
            return c
        }
        var preset = Preset.flatDefault
        preset.evento = "EV"; preset.folderStructure = "{evento}/{lote}/{tipo}"
        let svc = CopyService(preset: preset, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)

        let c1 = try card("CARD1", "C0001")
        _ = try svc.run(cardRoot: c1, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/Lote 01/Video/C0001.MP4").path))

        let c2 = try card("CARD2", "C0002")   // conteúdo disjunto (cartão formatado)
        _ = try svc.run(cardRoot: c2, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/Lote 02/Video/C0002.MP4").path))

        // re-rodar o CARD1 (mesmo conteúdo do Lote 01) não cria Lote 03
        _ = try svc.run(cardRoot: c1, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("EV/Lote 03").path))
    }

    // Opt-in: estrutura SEM {lote} não separa e preview.lote é nil (comportamento de antes intacto).
    @Test func semTokenLoteNaoSeparaEPreviewLoteNil() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let dest = work.appendingPathComponent("DEST")
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data(count: 1000))
        var preset = Preset.flatDefault
        preset.evento = "EV"; preset.folderStructure = "{evento}/{tipo}"   // SEM {lote}
        let svc = CopyService(preset: preset, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let pv = try svc.preview(cardRoot: card, chosenMedia: .video, destinations: [dest])
        #expect(pv.lote == nil)
        _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("EV/Video/C0001.MP4").path))   // sem "Lote NN"
    }

    @Test func pipelineVerifiesManyFilesToTwoDestinations() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        for i in 0..<12 {
            let data = Data("clip-\(i)".utf8) + Data((0..<5000).map { UInt8(($0 + i) & 0xFF) })
            fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C\(String(format: "%04d", i)).MP4").path, contents: data)
        }
        let d1 = work.appendingPathComponent("SSD"); let d2 = work.appendingPathComponent("HD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let o = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [d1, d2], camera: "Cam")

        #expect(o.verifiedCount == 24)   // 12 vídeos × 2 destinos, todos conferidos byte a byte
        #expect(o.failures.isEmpty)
        for i in 0..<12 {
            let rel = "Offload/Video/C\(String(format: "%04d", i)).MP4"
            #expect(fm.fileExists(atPath: d1.appendingPathComponent(rel).path))
            #expect(fm.fileExists(atPath: d2.appendingPathComponent(rel).path))
        }
    }

    @Test func skipSidecarsByDefaultDoesNotCopyXml() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4").path, contents: Data("video".utf8))
        fm.createFile(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001M01.XML").path, contents: Data("<meta/>".utf8))
        let dest = work.appendingPathComponent("SSD")

        var p = Preset.flatDefault
        p.copySidecars = .skip
        let o = try CopyService(preset: p, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
            .run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")

        #expect(o.verifiedCount == 1)        // só o vídeo
        #expect(o.sidecarsCopied == 0)
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Offload/.cardflow/sidecars/PRIVATE/M4ROOT/CLIP/C0001M01.XML").path))
    }

    // O CAMINHO MAIS CRÍTICO: se a conferência falha (corrupção/disco ruim), a falha PRECISA ser
    // reportada (pra UI dizer "não formate") e o arquivo corrompido removido. Nunca luz verde com dado ruim.
    @Test func verifyFailureIsReportedAndCorruptRemoved() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("video".utf8))
        let dest = work.appendingPathComponent("SSD")

        // copiador que GRAVA normal mas a conferência SEMPRE reprova (simula corrupção na gravação)
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: .current, copier: FailingVerifyCopier())
        let o = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")

        #expect(o.verifiedCount == 0)                                   // nada conferido
        #expect(!o.failures.isEmpty)                                    // a falha É reportada → "não formate"
        #expect(o.failures.contains { $0.hasSuffix("C0001.MP4") })
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Offload/Video/C0001.MP4").path))  // corrompido removido
    }

    /// Lista os NOMES de todos os arquivos (não-pastas) sob um diretório, recursivamente.
    private func filesRecursively(under dir: URL) -> [String] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in en {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir { out.append(u.lastPathComponent) }
        }
        return out
    }

    // #1: depois de um run que deu certo, NENHUM `.cardflow-partial` sobra — tudo que foi conferido
    // virou nome final via rename atômico. Logo, todo arquivo de nome final no destino está íntegro.
    @Test func successfulRunLeavesNoPartialFiles() throws {
        let card = try FakeCard(); defer { card.cleanup() }
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .sampleConferencia, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        let o = try svc.run(cardRoot: card.root, chosenMedia: .both, destinations: [dest], camera: "Cam01")
        #expect(o.failures.isEmpty)
        let partials = filesRecursively(under: dest).filter { $0.hasSuffix(CopyService.partialSuffix) }
        #expect(partials.isEmpty)
        // e o arquivo final existe (foi promovido a partir do parcial)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Conferencia-Junho-2026/Foto/DSC00001.JPG").path))
    }

    // #2: corte no meio (disco enche). O run lança, mas ANTES de sair: drena a verificação (nada de
    // closure async mexendo no disco depois), limpa o parcial que estourou, mantém os arquivos já
    // conferidos com nome final, e grava um manifesto PARCIAL marcado como interrompido.
    @Test func interruptedRunDrainsVerifyCleansPartialsAndWritesPartialManifest() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        for i in 0..<3 {
            let data = Data("clip-\(i)".utf8) + Data((0..<3000).map { UInt8(($0 + i) & 0xFF) })
            fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C\(String(format: "%04d", i)).MP4").path, contents: data)
        }
        let dest = work.appendingPathComponent("SSD")

        // copiador que grava 1 arquivo OK e estoura no 2º (cria o parcial com bytes incompletos e falha)
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: .current, copier: FailAfterNCopier(succeed: 1))
        #expect(throws: (any Error).self) {
            _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        }

        // nenhum parcial sobra
        let partials = filesRecursively(under: dest).filter { $0.hasSuffix(CopyService.partialSuffix) }
        #expect(partials.isEmpty)
        // o arquivo que copiou+conferiu ANTES da falha ficou com nome final
        let finais = filesRecursively(under: dest).filter { $0.uppercased().hasSuffix(".MP4") }
        #expect(finais.count == 1)
        // manifesto PARCIAL gravado e marcado como interrompido
        let manifests = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Offload")
        #expect(manifests.count == 1)
        #expect(manifests.first?.interrupted == true)
        #expect(manifests.first?.totals.verified == 1)
    }

    // #5: cancelamento entre arquivos para limpo (nada de parcial), preserva os já copiados e
    // registra manifesto parcial. Mesma maquinaria da interrupção, disparada pelo botão Parar.
    @Test func cancellationBetweenFilesStopsCleanly() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        for i in 0..<4 {
            let data = Data("clip-\(i)".utf8) + Data((0..<2000).map { UInt8(($0 + i) & 0xFF) })
            fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C\(String(format: "%04d", i)).MP4").path, contents: data)
        }
        let dest = work.appendingPathComponent("SSD")
        var calls = 0
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        #expect(throws: OffloadError.cancelled) {
            _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam",
                            isCancelled: { calls += 1; return calls > 1 })   // cancela cedo (entre/dentro de arquivo)
        }
        // invariantes (independem de quantos blocos/arquivos passaram antes do cancelamento):
        // nenhum parcial sobra e o que sobrou foi registrado num manifesto marcado como interrompido.
        let partials = filesRecursively(under: dest).filter { $0.hasSuffix(CopyService.partialSuffix) }
        #expect(partials.isEmpty)
        let manifests = try ManifestStore().loadAll(eventRootIn: dest, eventName: "Offload")
        #expect(manifests.first?.interrupted == true)
    }

    // #28: filtro "só hoje" (capturedSince) copia só os arquivos planos a partir da data; antigos ficam.
    @Test func capturedSinceFiltersOlderFlatFiles() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        let oldFile = card.appendingPathComponent("DCIM/100/OLD.MP4")
        let newFile = card.appendingPathComponent("DCIM/100/NEW.MP4")
        fm.createFile(atPath: oldFile.path, contents: Data("antigo".utf8))
        fm.createFile(atPath: newFile.path, contents: Data("recente".utf8))
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        let newDate = Date(timeIntervalSince1970: 1_780_000_000)
        try fm.setAttributes([.creationDate: oldDate, .modificationDate: oldDate], ofItemAtPath: oldFile.path)
        try fm.setAttributes([.creationDate: newDate, .modificationDate: newDate], ofItemAtPath: newFile.path)
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let o = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam",
                            capturedSince: Date(timeIntervalSince1970: 1_500_000_000))
        #expect(o.verifiedCount == 1)   // só o recente
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/Video/NEW.MP4").path))
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("Offload/Video/OLD.MP4").path))
    }

    // Retomada RÁPIDA: a 2ª rodada pula os arquivos que o manifesto anterior já conferiu, sem reler —
    // confiando na verificação anterior (escolha do usuário). Provado: adultera o destino (mesmo
    // tamanho, sem mexer no manifesto) e a retomada rápida NÃO relê, então não recopia.
    @Test func fastResumeTrustsManifestAndSkipsWithoutRehashing() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("conteudo-original".utf8))
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        let o1 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o1.verifiedCount == 1)

        // adultera o destino com OUTRO conteúdo do MESMO tamanho, sem tocar no manifesto
        let destFile = dest.appendingPathComponent("Offload/Video/C0001.MP4")
        try Data("conteudo-trocado!".utf8).write(to: destFile)   // mesmo nº de bytes

        let o2 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam", fastResume: true)
        #expect(o2.verifiedCount == 0)                       // pulou sem reconferir
        #expect(o2.skipped.contains("DCIM/100/C0001.MP4"))
        #expect(try Data(contentsOf: destFile) == Data("conteudo-trocado!".utf8))   // não recopiou (trade-off)
    }

    // Cenário real: backup completo, esqueceu de formatar, continuou gravando. Re-rodar deve copiar
    // SÓ os arquivos novos e PULAR os já copiados (não recopiar tudo).
    @Test func incrementalRunCopiesOnlyNewFilesNotEverything() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0000.MP4").path, contents: Data("video-0".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("video-1".utf8))
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)

        let o1 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o1.verifiedCount == 2)

        // esqueceu de formatar e gravou mais 2 vídeos no mesmo cartão
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0002.MP4").path, contents: Data("video-2-novo".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0003.MP4").path, contents: Data("video-3-novo".utf8))

        let o2 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o2.verifiedCount == 2)   // SÓ os 2 novos foram copiados+conferidos
        #expect(Set(o2.skipped) == Set(["DCIM/100/C0000.MP4", "DCIM/100/C0001.MP4"]))   // os 2 antigos, pulados
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/Video/C0002.MP4").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/Video/C0003.MP4").path))
        // nenhuma duplicata: exatamente 4 vídeos no destino
        let videos = filesRecursively(under: dest).filter { $0.uppercased().hasSuffix(".MP4") }
        #expect(videos.count == 4)
    }

    // Renomear NÃO atrapalha o pulo: o app compara o nome de destino que o PRESET GERA (não o nome da
    // câmera). Como a regra é determinística, o mesmo arquivo gera o mesmo nome de destino → é pulado.
    @Test func incrementalSkipWorksEvenWhenPresetRenamesToDifferentName() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("filmagem".utf8))
        var p = Preset.flatDefault
        p.evento = "Culto"
        // renomeia pra um nome TOTALMENTE diferente do da câmera
        p.rename = .init(enabled: true, template: "{evento}_{ano}-{mes}-{dia}_{nome_original}", counterPadding: 4)
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: p, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)

        let o1 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o1.verifiedCount == 1)
        // o arquivo no destino tem nome renomeado (começa com "Culto_"), diferente de "C0001.MP4"
        let copiados = filesRecursively(under: dest).filter { $0.uppercased().hasSuffix(".MP4") }
        #expect(copiados.count == 1)
        #expect(copiados.first?.hasPrefix("Culto_") == true)
        #expect(copiados.first != "C0001.MP4")

        // re-rodar: reconhece e PULA, mesmo o nome no destino sendo diferente do da câmera
        let o2 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o2.verifiedCount == 0)
        #expect(o2.skipped.contains("DCIM/100/C0001.MP4"))
        #expect(filesRecursively(under: dest).filter { $0.uppercased().hasSuffix(".MP4") }.count == 1)   // sem duplicata
    }

    // Mesmo cenário com preset de CONTADOR: enquanto os arquivos novos vêm DEPOIS (números maiores,
    // o caso normal de câmera), os antigos mantêm o número e são pulados; só os novos são copiados.
    @Test func incrementalRunWithCounterSkipsOldWhenNewFilesSortAfter() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0000.MP4").path, contents: Data("a".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("b".utf8))
        var p = Preset.flatDefault
        p.rename = .init(enabled: true, template: "{contador}_{nome_original}", counterPadding: 4)
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: p, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")

        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0002.MP4").path, contents: Data("c-novo".utf8))
        let o2 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o2.verifiedCount == 1)                              // só o novo
        #expect(o2.skipped.contains("DCIM/100/C0000.MP4"))         // antigos mantêm o número → pulados
        #expect(o2.skipped.contains("DCIM/100/C0001.MP4"))
        let videos = filesRecursively(under: dest).filter { $0.uppercased().hasSuffix(".MP4") }
        #expect(videos.count == 3)                                 // sem duplicata
    }

    // A prévia conta quantas mídias já estão no destino → a UI decide entre "Iniciar" e "Retomar".
    @Test func previewCountsAlreadyPresentForResumeDetection() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0000.MP4").path, contents: Data("v0".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("v1".utf8))
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")

        // prévia agora: tudo já presente (não é retomada — está completo)
        let p1 = try svc.preview(cardRoot: card, chosenMedia: .video, destinations: [dest])
        #expect(p1.alreadyPresent == 2)
        #expect(p1.selectedCount == 2)

        // chega um 3º vídeo no cartão → prévia mostra 2 de 3: É uma retomada
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0002.MP4").path, contents: Data("v2".utf8))
        let p2 = try svc.preview(cardRoot: card, chosenMedia: .video, destinations: [dest])
        #expect(p2.alreadyPresent == 2)
        #expect(p2.selectedCount == 3)
    }

    // A checagem de espaço desconta o que já está no disco: uma retomada não é barrada por "sem espaço"
    // contando arquivos que já estão lá (e não serão reescritos).
    @Test func resumeNotBlockedBySpaceForAlreadyPresentFiles() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("um video qualquer".utf8))
        let dest = work.appendingPathComponent("SSD")
        // 1ª rodada: espaço sobrando, copia e escreve o manifesto
        _ = try CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
            .run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        // 2ª rodada: disco "sem espaço" (0 bytes, margem 0). Sem o desconto isto BLOQUEARIA; com o
        // desconto, o arquivo já verificado precisa de 0 bytes → retoma sem erro.
        let o2 = try CopyService(preset: .flatDefault, spaceProvider: FixedSpace(bytes: 0),
                                 timeZone: .current, marginBytes: 0)
            .run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        #expect(o2.failures.isEmpty)
        #expect(o2.skipped.contains("DCIM/100/C0001.MP4"))
    }

    // Sem retomada rápida (reconferência completa) a adulteração É detectada e o arquivo é recopiado.
    @Test func fullVerifyResumeDetectsTamperedDest() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("conteudo-original".utf8))
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
        _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        try Data("conteudo-trocado!".utf8).write(to: dest.appendingPathComponent("Offload/Video/C0001.MP4"))

        let o2 = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam", fastResume: false)
        #expect(o2.verifiedCount == 1)   // reconferiu, viu diferente, gravou cópia (não confiou)
    }

    // #3: arquivo não reconhecido (formato desconhecido) NÃO é deixado pra trás — é copiado verbatim
    // e conferido pra .cardflow/desconhecidos, como rede de segurança contra perder footage de um formato novo.
    @Test func unknownFilesAreCopiedToSafetyNetNotLeftBehind() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("video".utf8))
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/MISTERIO.xyz").path, contents: Data("formato-novo".utf8))
        let dest = work.appendingPathComponent("SSD")
        let o = try CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(), timeZone: .current)
            .run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")

        #expect(o.failures.isEmpty)
        #expect(o.unrecognized == ["DCIM/100/MISTERIO.xyz"])   // ainda listado como não-reconhecido
        // mas agora ele EXISTE no destino (copiado verbatim na rede de segurança), não foi perdido
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Offload/.cardflow/desconhecidos/DCIM/100/MISTERIO.xyz").path))
        #expect(try Data(contentsOf: dest.appendingPathComponent("Offload/.cardflow/desconhecidos/DCIM/100/MISTERIO.xyz")) == Data("formato-novo".utf8))
        #expect(o.canSafelyFormatCard)   // mídia + desconhecido salvos e conferidos → pode formatar
    }

    // #21: 2 SSDs, um arquivo verifica num e falha no outro → cada manifesto é FIEL ao seu disco
    // (o disco que falhou não afirma ter o arquivo), e o cartão NÃO pode ser formatado.
    @Test func twoDisksOneCorruptManifestIsHonestPerDisk() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("video".utf8))
        let ssd = work.appendingPathComponent("SSD")
        let hd = work.appendingPathComponent("HD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: .current, copier: FailVerifyOnDest(marker: "/HD/"))
        let o = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [ssd, hd], camera: "Cam")

        #expect(o.failures.count == 1)            // a falha do HD é reportada
        #expect(!o.canSafelyFormatCard)           // uma cópia falhou → não pode formatar
        // SSD: tem o arquivo; manifesto lista 1 verificado
        let ssdM = try ManifestStore().loadAll(eventRootIn: ssd, eventName: "Offload")
        #expect(ssdM.first?.files.count == 1)
        #expect(ssdM.first?.totals.verified == 1)
        // HD: NÃO tem o arquivo; manifesto não mente sobre ele
        let hdM = try ManifestStore().loadAll(eventRootIn: hd, eventName: "Offload")
        #expect(hdM.first?.files.isEmpty == true)
        #expect(hdM.first?.totals.verified == 0)
    }

    // Parar responsivo: cancelamento no MEIO de um arquivo grande (não só entre arquivos). O copiador
    // checa o sinal por bloco e lança; o run trata como .cancelled, limpa parcial e não deixa nada meia-boca.
    @Test func cancellationMidFileStopsWithinAFile() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        // um vídeo grande o bastante pra ter vários blocos de cópia
        let big = Data((0..<2_000_000).map { UInt8($0 & 0xFF) })   // 2 MB
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: big)
        let dest = work.appendingPathComponent("SSD")
        var chunks = 0
        // copiador com blocos pequenos pra cancelar no meio do arquivo
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: .current, copier: FileCopier(chunkSize: 64 * 1024))
        #expect(throws: OffloadError.cancelled) {
            _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam",
                            isCancelled: { chunks += 1; return chunks > 2 })   // cancela já no 3º bloco
        }
        // nada de parcial nem de arquivo final meia-boca
        let leftovers = filesRecursively(under: dest).filter { $0.hasSuffix(CopyService.partialSuffix) || $0.uppercased().hasSuffix(".MP4") }
        #expect(leftovers.isEmpty)
    }

    // #15: disco cheio (ENOSPC) no meio vira erro CLARO (diskFullDuringCopy), não I/O genérico em inglês.
    @Test func diskFullDuringCopyGivesClearError() throws {
        let work = try tempDir(); defer { try? FileManager.default.removeItem(at: work) }
        let fm = FileManager.default
        let card = work.appendingPathComponent("CARD")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100"), withIntermediateDirectories: true)
        fm.createFile(atPath: card.appendingPathComponent("DCIM/100/C0001.MP4").path, contents: Data("video".utf8))
        let dest = work.appendingPathComponent("SSD")
        let svc = CopyService(preset: .flatDefault, spaceProvider: AlwaysEnoughSpace(),
                              timeZone: .current, copier: FailAfterNCopier(succeed: 0))   // estoura ENOSPC no 1º
        #expect(throws: OffloadError.diskFullDuringCopy) {
            _ = try svc.run(cardRoot: card, chosenMedia: .video, destinations: [dest], camera: "Cam")
        }
    }
}

private struct AlwaysEnoughSpace: FreeSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64 { Int64.max }
}
private struct FixedSpace: FreeSpaceProviding {
    let bytes: Int64
    func availableBytes(at url: URL) throws -> Int64 { bytes }
}

/// Grava de verdade (delega ao FileCopier real) mas a conferência SEMPRE reprova — pra testar
/// que uma corrupção de gravação vira falha reportada, não luz verde.
private struct FailingVerifyCopier: FileCopying {
    private let real = FileCopier()
    func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void, isCancelled: () -> Bool) throws -> UInt64 {
        try real.copy(source: source, to: destinations, onChunk: onChunk, isCancelled: isCancelled)
    }
    func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool { false }
}

/// Copia `succeed` arquivos normalmente e, no seguinte, simula disco enchendo no meio: cria o(s)
/// parcial(is) com bytes incompletos e lança ENOSPC. Pra exercer o caminho de interrupção.
private final class FailAfterNCopier: FileCopying {
    private let real = FileCopier()
    private let succeed: Int
    private var count = 0
    init(succeed: Int) { self.succeed = succeed }
    func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void, isCancelled: () -> Bool) throws -> UInt64 {
        defer { count += 1 }
        if count >= succeed {
            let fm = FileManager.default
            for d in destinations {
                try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: d.path, contents: Data("incompleto".utf8))
            }
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        return try real.copy(source: source, to: destinations, onChunk: onChunk)
    }
    func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool {
        try real.verify(expectedHash: expectedHash, fileAt: url)
    }
}

/// Grava normal nos dois destinos, mas a conferência SEMPRE reprova no destino cujo caminho contém
/// `marker` (simula um SSD que corrompe). Pra testar manifesto fiel por disco (#21).
private struct FailVerifyOnDest: FileCopying {
    private let real = FileCopier()
    let marker: String
    func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void, isCancelled: () -> Bool) throws -> UInt64 {
        try real.copy(source: source, to: destinations, onChunk: onChunk, isCancelled: isCancelled)
    }
    func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool {
        if url.path.contains(marker) { return false }   // este disco "corrompe"
        return try real.verify(expectedHash: expectedHash, fileAt: url)
    }
}
