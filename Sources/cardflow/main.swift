import Foundation
import OffloadKit
import CardflowCLI

// O macOS injeta args de NSGlobalDomain (ex.: `-AppleLanguages "(en)"`, usado pra forçar idioma)
// em argv. O Cocoa consome via NSUserDefaults, mas a CLI tem parser próprio e veria essas flags
// como argumento inválido. Filtramos o par flag+valor antes de parsear; o idioma já foi lido pelo
// runtime (Locale.preferredLanguages) na inicialização.
let raw = ArgParser.dropSystemDefaultsArgs(Array(CommandLine.arguments.dropFirst()))

if raw.contains("--help") || raw.contains("-h") || raw.isEmpty {
    print(CardflowHelp.text)
    exit(raw.isEmpty ? 1 : 0)
}

do {
    let config = try ArgParser.parse(raw)
    try CardflowRunner.run(config,
                           input: { prompt in print(prompt, terminator: ""); return readLine() },
                           output: { print($0) })
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
