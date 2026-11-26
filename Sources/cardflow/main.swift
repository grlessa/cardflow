import Foundation
import OffloadKit
import CardflowCLI

// O macOS injeta args de NSGlobalDomain (ex.: `-AppleLanguages "(en)"`, usado pra forçar idioma)
// em argv. O Cocoa consome via NSUserDefaults, mas a CLI tem parser próprio e veria essas flags
// como argumento inválido. Filtramos o par flag+valor antes de parsear; o idioma já foi lido pelo
// runtime (Locale.preferredLanguages) na inicialização.
let raw = ArgParser.dropSystemDefaultsArgs(Array(CommandLine.arguments.dropFirst()))

if raw.contains("--version") || raw.contains("-V") {
    print("cardflow \(OffloadKit.version)")
    exit(0)
}

if raw.contains("--help") || raw.contains("-h") || raw.isEmpty {
    print(CardflowHelp.text)
    exit(raw.isEmpty ? 1 : 0)
}

let interactiveStderr = isatty(STDERR_FILENO) != 0
final class CLIProgressPrinter {
    private var lastPrint = Date.distantPast
    func report(_ p: OffloadProgress) {
        let now = Date()
        guard now.timeIntervalSince(lastPrint) >= 0.2 || p.filesDone == p.filesTotal else { return }
        lastPrint = now
        let pct = p.bytesTotal > 0
            ? min(100, Int((Double(p.bytesDone) / Double(p.bytesTotal) * 100).rounded()))
            : 100
        let line = "\r[\(pct)%] \(p.filesDone)/\(p.filesTotal) (\(Report.humanBytes(p.bytesDone))/\(Report.humanBytes(p.bytesTotal)))"
        FileHandle.standardError.write(Data(line.utf8))
        if p.filesDone == p.filesTotal {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
let progressPrinter = interactiveStderr ? CLIProgressPrinter() : nil

do {
    let config = try ArgParser.parse(raw)
    try CardflowRunner.run(config,
                           input: { prompt in print(prompt, terminator: ""); return readLine() },
                           output: { print($0) },
                           onProgress: progressPrinter.map { printer in { printer.report($0) } })
} catch let e as CardflowRunError {
    FileHandle.standardError.write(Data((CLIErrorReport.line(for: e) + "\n").utf8))
    switch e {
    case .verificationFailed: exit(3)   // mídia NÃO verificou — não formate o cartão
    case .noSpace:            exit(4)   // sem espaço no destino
    case .sameDisk:          exit(2)    // uso inválido (destinos no mesmo disco)
    }
} catch {
    FileHandle.standardError.write(Data((CLIErrorReport.line(for: error) + "\n").utf8))
    exit(2)                             // erro de argumento / preset inválido
}
