import Testing
@testable import CardflowCLI
@testable import OffloadKit
import Foundation

@Suite struct ReportTests {
    @Test func verdictOkWhenNoFailures() {
        let o = OffloadOutcome(verifiedCount: 6, failures: [], unrecognized: [], skipped: [])
        let v = Report.verdict(o)
        #expect(v.ok == true)
        #expect(v.line.contains("Pode formatar"))
    }

    @Test func verdictNotOkWhenFailures() {
        let o = OffloadOutcome(verifiedCount: 4, failures: ["E/FOTO/x.jpg"], unrecognized: [], skipped: [])
        let v = Report.verdict(o)
        #expect(v.ok == false)
        #expect(v.line.contains("NÃO formate"))
    }

    @Test func summaryMentionsCountsAndShortfall() {
        let pv = OffloadPreview(photos: 2, videos: 1, audios: 0, cinema: 0, junk: 0, selectedCount: 3, totalBytes: 7168,
                                unrecognized: ["MISC/notas.txt"], shortfalls: [])
        let s = Report.summary(preview: pv, destinations: [URL(fileURLWithPath: "/Volumes/SSD")])
        #expect(s.contains("2 foto"))
        #expect(s.contains("1 vídeo"))
        #expect(s.contains("notas.txt"))
    }

    @Test func summaryMentionsCinemaClipsWhenPresent() {
        let comCinema = OffloadPreview(photos: 0, videos: 0, audios: 0, cinema: 2, junk: 0, selectedCount: 14,
                                       totalBytes: 9_000_000, unrecognized: [], shortfalls: [])
        #expect(Report.summary(preview: comCinema, destinations: [URL(fileURLWithPath: "/Volumes/SSD")]).contains("2 clipe(s) de cinema"))
        // sem cinema, a linha não menciona clipes
        let semCinema = OffloadPreview(photos: 1, videos: 0, audios: 0, cinema: 0, junk: 0, selectedCount: 1,
                                       totalBytes: 100, unrecognized: [], shortfalls: [])
        #expect(!Report.summary(preview: semCinema, destinations: [URL(fileURLWithPath: "/x")]).contains("clipe"))
    }

    @Test func outcomeMentionsSidecarsAndManifest() {
        let o = OffloadOutcome(verifiedCount: 4, failures: [], unrecognized: [], skipped: [],
                               sidecarsCopied: 2, cardAlreadyCopied: false,
                               manifestPaths: ["/Volumes/SSD/Conf/.cardflow/manifest-x.json"])
        let s = Report.outcome(o)
        #expect(s.contains("Sidecars: 2"))
        #expect(s.contains("manifest-x.json"))
    }

    @Test func outcomeMentionsRelocatedCinema() {
        let o = OffloadOutcome(verifiedCount: 2, failures: [], unrecognized: [], skipped: [],
                               sidecarsCopied: 0, cardAlreadyCopied: false, manifestPaths: [],
                               relocatedCinema: ["A001.RDM"])
        let s = Report.outcome(o)
        #expect(s.contains("movido"))
        #expect(s.contains("A001.RDM"))
        // sem relocados, nenhuma linha de aviso
        let limpo = OffloadOutcome(verifiedCount: 1, failures: [], unrecognized: [], skipped: [])
        #expect(!Report.outcome(limpo).contains("movido"))
    }
}
