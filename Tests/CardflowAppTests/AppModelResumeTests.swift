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

        // Pós-i18n o texto mora no catálogo (resolvido só no .app). No teste, String(localized:)
        // cai na chave; então verificamos a chave do estado + os números que o model calcula.
        #expect(model.resumeCardTitle == "main.resume.title")
        let detail = model.resumeCardDetail ?? ""
        #expect(detail.hasPrefix("main.resume.detail"))
        #expect(detail.contains("10") && detail.contains("26") && detail.contains("445.1 MB"))
        #expect(model.resumeActionHint == "main.resume.hint")
        #expect(model.verifiedResumeHelpText == "main.resume.verifiedHelp")
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
        // complemento usa a chave de complemento (≠ retomada) — distingue o estado no nível da mensagem
        #expect(model.resumeCardTitle == "main.resume.complementTitle")
        let detail = model.resumeCardDetail ?? ""
        #expect(detail.hasPrefix("main.resume.complementDetail"))
        #expect(detail.contains("36") && detail.contains("181") && detail.contains("168.3 GB"))
        #expect(model.resumeActionHint?.hasPrefix("main.resume.complementHint") == true)
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
        #expect(model.resumeCardTitle == "main.resume.title")
        #expect(model.resumeActionHint == "main.resume.hint")
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
        #expect(model.alreadyCopiedTitle == "main.alreadyCopied.title")
        let detail = model.alreadyCopiedDetail ?? ""
        #expect(detail.hasPrefix("main.alreadyCopied.detail"))
        #expect(detail.contains("36"))
    }
}
