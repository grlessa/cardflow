import Foundation
import OffloadKit
import CardflowCLI

let raw = Array(CommandLine.arguments.dropFirst())

if raw.contains("--help") || raw.contains("-h") || raw.isEmpty {
    print("""
    cardflow — offload verificado de cartão (teste do motor OffloadKit)

    uso:
      cardflow --card <caminho> --to <destino> [--to <destino2>] \\
               [--media both|foto|video] [--camera <nome>] [--evento <nome>] \\
               [--rename] [--dry-run] [--yes] [--preset <arquivo.json>]
    """)
    exit(raw.isEmpty ? 1 : 0)
}

do {
    let config = try ArgParser.parse(raw)
    try CardflowRunner.run(config,
                           input: { prompt in print(prompt, terminator: ""); return readLine() },
                           output: { print($0) })
} catch let e as CardflowRunError {
    FileHandle.standardError.write(Data("erro: \(e)\n".utf8))
    switch e {
    case .verificationFailed: exit(3)   // mídia NÃO verificou — não formate o cartão
    case .noSpace:            exit(4)   // sem espaço no destino
    case .sameDisk:          exit(2)    // uso inválido (destinos no mesmo disco)
    }
} catch {
    FileHandle.standardError.write(Data("erro: \(error)\n".utf8))
    exit(2)                             // erro de argumento / preset inválido
}
