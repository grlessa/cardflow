import Foundation

public struct CardScanner {
    private let classifier: FileClassifier
    public init(classifier: FileClassifier) { self.classifier = classifier }

    public func scan(cardRoot: URL) throws -> [MediaFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: cardRoot, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        let rootPath = cardRoot.standardizedFileURL.path
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
            // captura: creationDate primeiro, cai pra modificationDate.
            let capture = values.creationDate ?? values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let size = Int64(values.fileSize ?? 0)
            let type = classifier.classify(relPath: rel, size: size)

            result.append(MediaFile(sourceURL: url, relPath: rel, size: size, type: type, captureDate: capture))
        }
        return PreservePlanner.plan(result.sorted { $0.relPath < $1.relPath })
    }
}
