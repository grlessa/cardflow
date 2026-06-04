import Foundation

public enum CardFingerprint {
    /// Impressão digital do conteúdo do cartão (independente de ordem): hash da lista
    /// ordenada de (relPath, size) + contagem + bytes totais. Não lê conteúdo dos arquivos.
    public static func compute(files: [MediaFile]) -> String {
        let joined = files.map { "\($0.relPath)\t\($0.size)" }.sorted().joined(separator: "\n")
        let h = XXHash64.hash(Data(joined.utf8))
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return String(format: "%016llx-%d-%lld", h, files.count, total)
    }
}
