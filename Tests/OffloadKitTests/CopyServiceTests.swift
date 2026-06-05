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
    func copy(source: URL, to destinations: [URL], onChunk: (Int) -> Void) throws -> UInt64 {
        try real.copy(source: source, to: destinations, onChunk: onChunk)
    }
    func verify(expectedHash: UInt64, fileAt url: URL) throws -> Bool { false }
}
