import Testing
import Foundation
@testable import CardflowApp
@testable import OffloadKit

@MainActor @Suite struct CardSessionTests {
    func session(_ pv: OffloadPreview, media: Preset.Media.Kind = .both) -> CardSession {
        let s = CardSession(volume: ExternalVolume(url: URL(fileURLWithPath: "/Volumes/A001"), name: "A001",
                                                   isRemovable: true, isInternal: false), mediaChoice: media)
        s.preview = pv; s.phase = .ready
        return s
    }
    func pv(selected: Int, present: Int = 0, interrupted: Int = 0, total: Int64 = 300, remaining: Int64 = 0,
            photos: Int? = nil, videos: Int = 0) -> OffloadPreview {
        var p = OffloadPreview(photos: photos ?? selected, videos: videos, audios: 0, cinema: 0, junk: 0,
                               selectedCount: selected, totalBytes: total, unrecognized: [], shortfalls: [],
                               alreadyPresent: present, alreadyPresentFromInterrupted: interrupted, remainingBytes: remaining)
        p.alreadyPresentFromInterrupted = interrupted
        return p
    }

    @Test func retomadaQuandoParteVeioDeCopiaInterrompida() {
        let s = session(pv(selected: 3, present: 1, interrupted: 1, remaining: 200))
        #expect(s.isResume && s.showsRemainingHeadline && s.headlineBytes == 200)
        #expect(!s.isAlreadyCopied)
    }
    @Test func jaCopiadoQuandoTudoEstaNoDestino() {
        let s = session(pv(selected: 2, present: 2))
        #expect(s.isAlreadyCopied && !s.isResume)
        #expect(s.statusLine == String(localized: "card.status.alreadyCopied"))
    }
    @Test func complementoQuandoAntesCopiouSoFotos() {
        let s = session(pv(selected: 5, present: 3, photos: 3, videos: 2))
        #expect(s.isComplementalCopy && !s.isResume)
        s.mediaChoice = .photo
        #expect(!s.isComplementalCopy)
    }
    @Test func cartaoVazio() {
        let s = session(pv(selected: 0))
        #expect(s.isEmpty && s.statusLine == String(localized: "card.status.empty"))
    }
    @Test func linhaDeStatusAcompanhaAFase() {
        let s = session(pv(selected: 1, total: 61_200_000_000))
        #expect(s.statusLine.contains("61"))
        s.phase = .queued
        #expect(s.statusLine == String(localized: "card.status.queued") && s.isBusy)
        s.phase = .running(OffloadProgress(phase: .copying, filesDone: 1, filesTotal: 2, bytesDone: 50, bytesTotal: 100))
        #expect(s.statusLine.contains("50"))
        s.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: []))
        #expect(s.statusLine == String(localized: "card.status.verified") && !s.isBusy)
        s.phase = .finished(OffloadOutcome(verifiedCount: 1, failures: ["x"], unrecognized: [], skipped: []))
        #expect(s.statusLine == String(localized: "card.status.failed"))
    }
    @Test func loteIncompletoTravaAteConfirmar() {
        var p = pv(selected: 2)
        p.lote = LoteDecision(numero: 2, isNovo: true, anteriorIncompleto: 1)
        let s = session(p)
        #expect(s.loteLossUnconfirmed)
        s.acknowledgedIncompleteLote = 1
        #expect(!s.loteLossUnconfirmed)
    }
}
