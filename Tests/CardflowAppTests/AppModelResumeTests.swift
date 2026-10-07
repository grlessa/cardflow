import Foundation
import Testing
@testable import OffloadKit
@testable import CardflowApp

@MainActor
@Suite struct AppModelResumeTests {
    @Test func verifiedResumeOptionOnlyAppearsForPartialResume() {
        let model = AppModel.withTestCard()

        model.cards[0].preview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 0, remainingBytes: 300)
        #expect(model.cards[0].showsVerifiedResumeOption == false)

        model.cards[0].preview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 3, remainingBytes: 0)
        #expect(model.cards[0].showsVerifiedResumeOption == false)

        model.cards[0].preview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 1, remainingBytes: 200)
        #expect(model.cards[0].showsVerifiedResumeOption)
    }

    @Test func resumeCopyUsesShortHumanText() {
        let model = AppModel.withTestCard()

        model.cards[0].preview = OffloadPreview(photos: 21, videos: 15, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 36, totalBytes: 1_100_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 10, remainingBytes: 445_100_000)

        // Pós-i18n o texto mora no catálogo (resolvido só no .app). No teste, String(localized:)
        // cai na chave; então verificamos a chave do estado + os números que o model calcula.
        #expect(model.cards[0].resumeCardTitle == "main.resume.title")
        let detail = model.cards[0].resumeCardDetail ?? ""
        #expect(detail.hasPrefix("main.resume.detail"))
        #expect(detail.contains("10") && detail.contains("26") && detail.contains("445.1 MB"))
        #expect(model.cards[0].resumeActionHint == "main.resume.hint")
    }

    @Test func copiedPhotosThenAllIsComplementNotResume() {
        let model = AppModel.withTestCard()
        model.cards[0].mediaChoice = .both

        model.cards[0].preview = OffloadPreview(photos: 36, videos: 181, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 217, totalBytes: 169_400_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, remainingBytes: 168_300_000_000)

        #expect(model.cards[0].isComplementalCopy)
        #expect(model.cards[0].isResume == false)
        #expect(model.cards[0].showsVerifiedResumeOption == false)
        // complemento usa a chave de complemento (≠ retomada) — distingue o estado no nível da mensagem
        #expect(model.cards[0].resumeCardTitle == "main.resume.complementTitle")
        let detail = model.cards[0].resumeCardDetail ?? ""
        #expect(detail.hasPrefix("main.resume.complementDetail"))
        #expect(detail.contains("36") && detail.contains("181") && detail.contains("168.3 GB"))
        #expect(model.cards[0].resumeActionHint?.hasPrefix("main.resume.complementHint") == true)
    }

    @Test func interruptedAllAfterPhotosStillShowsResume() {
        let model = AppModel.withTestCard()
        model.cards[0].mediaChoice = .both

        model.cards[0].preview = OffloadPreview(photos: 36, videos: 181, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 217, totalBytes: 169_400_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, alreadyPresentFromInterrupted: 36,
                                           remainingBytes: 168_300_000_000)

        #expect(model.cards[0].isComplementalCopy == false)
        #expect(model.cards[0].isResume)
        #expect(model.cards[0].showsVerifiedResumeOption)
        #expect(model.cards[0].resumeCardTitle == "main.resume.title")
        #expect(model.cards[0].resumeActionHint == "main.resume.hint")
    }

    // Bug real: cartão não formatado reusado pro lote SEGUINTE. Parte já está salva (lote anterior
    // CONCLUÍDO, não interrompido) e o app detectou um lote NOVO. Não é "Retomar" — é um lote novo,
    // com o material antigo reconhecido como já salvo. O headline mostra o que falta, não o total.
    @Test func loteNovoComArquivosJaSalvosNaoEhRetomada() {
        let model = AppModel.withTestCard()
        model.cards[0].preview = OffloadPreview(photos: 0, videos: 5, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 5, totalBytes: 500,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 3, alreadyPresentFromInterrupted: 0,
                                           remainingBytes: 200,
                                           lote: LoteDecision(numero: 2, isNovo: true, anteriorIncompleto: nil))
        #expect(model.cards[0].isResume == false)
        #expect(model.cards[0].showsVerifiedResumeOption == false)
        #expect(model.cards[0].showsRemainingHeadline)
        #expect(model.cards[0].headlineBytes == 200)
    }

    // Guarda: retomada de cópia INTERROMPIDA continua sendo "Retomar", mesmo com {lote} (lote incompleto).
    @Test func retomadaDeLoteIncompletoContinuaSendoRetomada() {
        let model = AppModel.withTestCard()
        model.cards[0].preview = OffloadPreview(photos: 0, videos: 5, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 5, totalBytes: 500,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 3, alreadyPresentFromInterrupted: 3,
                                           remainingBytes: 200,
                                           lote: LoteDecision(numero: 1, isNovo: false, anteriorIncompleto: nil))
        #expect(model.cards[0].isResume)
    }

    @Test func alreadyCopiedPreviewBlocksStartAndExplainsStatus() {
        let model = AppModel.withTestCard()
        let card = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD"),
                                  name: "CARD", isRemovable: true, isInternal: false)
        let dest = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/SSD"),
                                  name: "SSD", isRemovable: false, isInternal: false)
        model.watcher.volumes = [card, dest]
        model.forcedSources.insert(card.id)
        model.destinationURL = dest.url

        model.cards[0].preview = OffloadPreview(photos: 36, videos: 0, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 36, totalBytes: 1_100_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, remainingBytes: 0)

        #expect(model.cards[0].isAlreadyCopied)
        #expect(model.canStart(model.cards[0]) == false)
        #expect(model.cards[0].alreadyCopiedTitle == "main.alreadyCopied.title")
        let detail = model.cards[0].alreadyCopiedDetail ?? ""
        #expect(detail.hasPrefix("main.alreadyCopied.detail"))
        #expect(detail.contains("36"))
    }

    @Test func headlineBytesUsesTotalForNewCopyAndRemainingForResume() {
        let model = AppModel.withTestCard()

        // cópia nova: número de destaque = total do cartão
        model.cards[0].preview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 0, remainingBytes: 300)
        #expect(model.cards[0].isResume == false)
        #expect(model.cards[0].showsRemainingHeadline == false)
        #expect(model.cards[0].headlineBytes == 300)

        // retomada: número de destaque = o que ainda falta copiar
        model.cards[0].preview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 1, remainingBytes: 200)
        #expect(model.cards[0].isResume)
        #expect(model.cards[0].showsRemainingHeadline)
        #expect(model.cards[0].headlineBytes == 200)
    }

    @Test func headlineBytesUsesRemainingForComplement() {
        let model = AppModel.withTestCard()
        model.cards[0].mediaChoice = .both

        model.cards[0].preview = OffloadPreview(photos: 36, videos: 181, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 217, totalBytes: 169_400_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, remainingBytes: 168_300_000_000)

        #expect(model.cards[0].isComplementalCopy)
        #expect(model.cards[0].showsRemainingHeadline)
        #expect(model.cards[0].headlineBytes == 168_300_000_000)
    }

    @Test func returnToStartAfterStopGoesIdleAndKeepsBackup() {
        let model = AppModel.withTestCard()
        let backup = URL(fileURLWithPath: "/Volumes/BACKUP")
        model.backupURL = backup
        let card = model.cards[0]
        card.isCancelling = true
        card.phase = .running(OffloadProgress(phase: .scanning, filesDone: 2, filesTotal: 10,
                                              bytesDone: 100, bytesTotal: 500))

        model.returnToStartAfterStop(card)

        #expect(card.isCancelling == false)
        #expect(card.phase == .ready)
        // preserva o backup: numa retomada com 2 discos, zerar mudaria a contagem de já-copiados
        #expect(model.backupURL == backup)
    }

    // A prévia (refreshCardPreview) e a cópia (startOffload) usam `previewPreset`, que aplica o
    // effectiveEvento. Sem isso, a prévia procura o manifesto parcial na pasta padrão do preset em vez
    // da pasta nomeada pelo usuário → não detecta a retomada e o botão fica "Iniciar" (bug real).
    @Test func previewPresetUsaEffectiveEventoParaDetectarRetomada() {
        let model = AppModel.withTestCard()
        // pasta-mãe padrão (eventName vazio): segue o evento do preset ativo, saneado.
        #expect(model.previewPreset.evento == model.effectiveEvento)
        #expect(model.previewPreset.evento == NameBuilder.sanitizePathComponent(model.activePreset.evento))
        // nome de pasta próprio: a prévia TEM que usar esse evento, igual ao que o startOffload grava.
        model.projectName = "Casamento Maria"
        #expect(model.previewPreset.evento == NameBuilder.sanitizePathComponent("Casamento Maria"))
        #expect(model.previewPreset.evento == model.effectiveEvento)
    }
}
