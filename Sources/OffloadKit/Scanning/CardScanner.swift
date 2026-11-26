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
        let canonicalRoot = cardRoot.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: canonicalRoot, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        let rootPath = canonicalRoot.path
        let rootSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        // fallback estável quando o FS não dá data NENHUMA do arquivo (raro, ex. exFAT estranho):
        // a data de modificação da RAIZ do cartão (≈ quando o cartão foi usado), em vez de 1970 —
        // que faria footage de hoje cair numa pasta "jan 1970" e parecer perdido. Estável entre
        // execuções (não muda em leitura), então não quebra a idempotência por nome/pasta.
        let rootFallback = (try? canonicalRoot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
        var result: [MediaFile] = []

        for case let url as URL in enumerator {
            var values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            // symlink -> resolve pro alvo (alguns fluxos usam link pra mídia real; sem isso a mídia sumia).
            if values.isRegularFile != true {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                guard let tv = try? resolved.resourceValues(forKeys: Set(keys)),
                      tv.isRegularFile == true else { continue }   // symlink quebrado / pra pasta -> ignora
                values = tv
            }

            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(rootSlash) else { continue }
            let rel = String(fullPath.dropFirst(rootSlash.count))
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
