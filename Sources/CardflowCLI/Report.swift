import Foundation
import OffloadKit

public enum Report {
    // fonte única (decimal, igual ao app e ao Finder) — era base 1024 aqui, divergindo do app.
    public static func humanBytes(_ bytes: Int64) -> String { Format.humanBytes(bytes) }

    public static func summary(preview p: OffloadPreview, destinations: [URL]) -> String {
        var lines: [String] = []
        var media = CLIStrings.string("report.summary.media %1$lld %2$lld", p.photos, p.videos)
        if p.audios > 0 { media += CLIStrings.string("report.summary.mediaAudio %lld", p.audios) }
        if p.cinema > 0 { media += CLIStrings.string("report.summary.cinema %lld", p.cinema) }
        lines.append(CLIStrings.string("report.summary.totals %1$@ %2$lld %3$@", media, p.selectedCount, humanBytes(p.totalBytes)))
        lines.append(CLIStrings.string("report.summary.destinations %@", destinations.map(\.path).joined(separator: ", ")))
        if !p.unrecognized.isEmpty {
            lines.append(CLIStrings.string("report.summary.unrecognized %@", p.unrecognized.joined(separator: ", ")))
        }
        for s in p.shortfalls {
            lines.append(CLIStrings.string("report.summary.shortfall %1$@ %2$@ %3$@", s.destination.path, humanBytes(s.required), humanBytes(s.available)))
        }
        return lines.joined(separator: "\n")
    }

    public static func outcome(_ o: OffloadOutcome) -> String {
        var lines: [String] = []
        lines.append(CLIStrings.string("report.outcome.header %1$lld %2$lld %3$lld %4$lld", o.verifiedCount, o.skipped.count, o.failures.count, o.sidecarsCopied))
        if o.cardAlreadyCopied { lines.append(CLIStrings.string("report.outcome.cardAlreadyCopied")) }
        if !o.failures.isEmpty { lines.append(CLIStrings.string("report.outcome.failures %@", o.failures.joined(separator: ", "))) }
        if !o.unrecognized.isEmpty { lines.append(CLIStrings.string("report.outcome.unrecognized %@", o.unrecognized.joined(separator: ", "))) }
        if !o.relocatedCinema.isEmpty {
            lines.append(CLIStrings.string("report.outcome.relocatedCinema %1$lld %2$@", o.relocatedCinema.count, o.relocatedCinema.joined(separator: ", ")))
        }
        if !o.manifestFailures.isEmpty {
            lines.append(CLIStrings.string("report.outcome.manifestFailures %@", o.manifestFailures.joined(separator: ", ")))
        }
        for p in o.manifestPaths { lines.append(CLIStrings.string("report.outcome.manifestPath %@", p)) }
        return lines.joined(separator: "\n")
    }

    public static func verdict(_ o: OffloadOutcome) -> (ok: Bool, line: String) {
        if o.canSafelyFormatCard {
            return (true, CLIStrings.string("report.verdict.ok"))
        } else {
            return (false, CLIStrings.string("report.verdict.notOk %lld", o.failures.count))
        }
    }
}
