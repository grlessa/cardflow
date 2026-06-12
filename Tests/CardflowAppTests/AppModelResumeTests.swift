import Foundation
import Testing
@testable import OffloadKit
@testable import CardflowApp

@MainActor
@Suite struct AppModelResumeTests {
    @Test func verifiedResumeOptionOnlyAppearsForPartialResume() {
        let model = AppModel()

        model.cardPreview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 0, remainingBytes: 300)
        #expect(model.showsVerifiedResumeOption == false)

        model.cardPreview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 3, remainingBytes: 0)
        #expect(model.showsVerifiedResumeOption == false)

        model.cardPreview = OffloadPreview(photos: 0, videos: 3, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 3, totalBytes: 300,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 1, remainingBytes: 200)
        #expect(model.showsVerifiedResumeOption)
    }

    @Test func resumeCopyUsesShortHumanText() {
        let model = AppModel()

        model.cardPreview = OffloadPreview(photos: 21, videos: 15, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 36, totalBytes: 1_100_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 10, remainingBytes: 445_100_000)

        #expect(model.resumeCardTitle == "Retomada detectada")
        #expect(model.resumeCardDetail == "10 já copiados · 26 novos · faltam 445.1 MB")
        #expect(model.resumeActionHint == "Continua de onde parou. Copia só o que falta.")
        #expect(model.verifiedResumeHelpText == "Mais lento. Confere os arquivos já copiados antes de continuar.")
    }

    @Test func copiedPhotosThenAllIsComplementNotResume() {
        let model = AppModel()
        model.mediaChoice = .both

        model.cardPreview = OffloadPreview(photos: 36, videos: 181, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 217, totalBytes: 169_400_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, remainingBytes: 168_300_000_000)

        #expect(model.isComplementalCopy)
        #expect(model.isResume == false)
        #expect(model.showsVerifiedResumeOption == false)
        #expect(model.resumeCardTitle == "Complemento detectado")
        #expect(model.resumeCardDetail == "36 fotos já copiadas · 181 novos · faltam 168.3 GB")
        #expect(model.resumeActionHint == "Fotos já copiadas serão ignoradas. Copia só o que falta.")
    }

    @Test func interruptedAllAfterPhotosStillShowsResume() {
        let model = AppModel()
        model.mediaChoice = .both

        model.cardPreview = OffloadPreview(photos: 36, videos: 181, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 217, totalBytes: 169_400_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, alreadyPresentFromInterrupted: 36,
                                           remainingBytes: 168_300_000_000)

        #expect(model.isComplementalCopy == false)
        #expect(model.isResume)
        #expect(model.showsVerifiedResumeOption)
        #expect(model.resumeCardTitle == "Retomada detectada")
        #expect(model.resumeActionHint == "Continua de onde parou. Copia só o que falta.")
    }

    @Test func alreadyCopiedPreviewBlocksStartAndExplainsStatus() {
        let model = AppModel()
        let card = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD"),
                                  name: "CARD", isRemovable: true, isInternal: false)
        let dest = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/SSD"),
                                  name: "SSD", isRemovable: false, isInternal: false)
        model.watcher.volumes = [card, dest]
        model.forcedSources.insert(card.id)
        model.selectedCardURL = card.url
        model.destinationURL = dest.url

        model.cardPreview = OffloadPreview(photos: 36, videos: 0, audios: 0, cinema: 0, junk: 0,
                                           selectedCount: 36, totalBytes: 1_100_000_000,
                                           unrecognized: [], shortfalls: [],
                                           alreadyPresent: 36, remainingBytes: 0)

        #expect(model.isAlreadyCopied)
        #expect(model.canStart == false)
        #expect(model.alreadyCopiedTitle == "Já está copiado")
        #expect(model.alreadyCopiedDetail == "36 arquivo(s) já estão no destino. Nada novo para copiar.")
    }
}
