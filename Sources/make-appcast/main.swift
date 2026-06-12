import Foundation
import OffloadKit

// Ferramenta de build (NÃO vai pro app do usuário): gera o appcast.xml a partir dos dados
// de uma release. Lê flags simples e imprime o XML no stdout.
func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func req(_ name: String) -> String {
    guard let v = arg(name) else {
        FileHandle.standardError.write(Data("make-appcast: falta \(name)\n".utf8)); exit(2)
    }
    return v
}

// Falha ruidosa em vez de gerar um appcast quebrado em silêncio: notas vazias ou
// length=0 só apareceriam pro usuário lá na frente, quando já é tarde.
let notesFile = req("--notes-file")
guard let notes = try? String(contentsOfFile: notesFile, encoding: .utf8) else {
    FileHandle.standardError.write(Data("make-appcast: não consegui ler o arquivo de notas \(notesFile)\n".utf8)); exit(2)
}
guard let length = Int(req("--length")) else {
    FileHandle.standardError.write(Data("make-appcast: --length precisa ser um número inteiro\n".utf8)); exit(2)
}
let xml = Appcast.xml(
    shortVersion: req("--short-version"),
    build: req("--build"),
    minimumSystemVersion: req("--min-system"),
    enclosureURL: req("--url"),
    edSignature: req("--ed-signature"),
    length: length,
    pubDate: req("--pubdate"),
    releaseNotesHTML: notes
)
print(xml)
