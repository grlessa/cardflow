import Foundation

public struct CardScanner {
    private let classifier: FileClassifier
    public init(classifier: FileClassifier) { self.classifier = classifier }

    /// Resolve a data de captura de um arquivo: criação, senão modificação, senão um fallback ESTÁVEL.
    /// Pura e testável de propósito — é o ponto onde um arquivo sem data do FS deixaria de ser "1970".
    static func resolveCapture(creation: Date?, modification: Date?, fallback: Date) -> Date {
        creation ?? modification ?? fallback
    }

    public func scan(cardRoot: URL) throws -> [MediaFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: cardRoot, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        let rootPath = cardRoot.standardizedFileURL.path
        // fallback estável quando o FS não dá data NENHUMA do arquivo (raro, ex. exFAT estranho):
        // a data de modificação da RAIZ do cartão (≈ quando o cartão foi usado), em vez de 1970 —
        // que faria footage de hoje cair numa pasta "jan 1970" e parecer perdido. Estável entre
        // execuções (não muda em leitura), então não quebra a idempotência por nome/pasta.
        let rootFallback = (try? cardRoot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
        var result: [MediaFile] = []

        for case let url as URL in enumerator {
            var values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            // symlink → resolve pro alvo (alguns fluxos usam link pra mídia real; sem isso a mídia sumia).
            if values.isRegularFile != true {
                guard let tv = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)),
                      tv.isRegularFile == true else { continue }   // symlink quebrado / pra pasta → ignora
                values = tv   // tamanho/data do ALVO; relPath e sourceURL seguem o do link (lê o alvo ao copiar)
            }

            let fullPath = url.standardizedFileURL.path
            var rel = fullPath
            if fullPath.hasPrefix(rootPath + "/") {
                rel = String(fullPath.dropFirst(rootPath.count + 1))
            }
            // captura: creationDate, senão modificationDate, senão a data da raiz do cartão (não 1970).
            let capture = Self.resolveCapture(creation: values.creationDate,
                                              modification: values.contentModificationDate,
                                              fallback: rootFallback)
            let size = Int64(values.fileSize ?? 0)
            let type = classifier.classify(relPath: rel, size: size)

            result.append(MediaFile(sourceURL: url, relPath: rel, size: size, type: type, captureDate: capture))
        }
        return PreservePlanner.plan(result.sorted { $0.relPath < $1.relPath })
    }
}
