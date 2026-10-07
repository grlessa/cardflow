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

    /// Identidade do volume de um cartão: o UUID do volume, quando a origem é a raiz de um volume montado.
    public static func volumeIdentity(of root: URL) -> String? {
        guard let v = try? root.resourceValues(forKeys: [.isVolumeKey, .volumeUUIDStringKey]), v.isVolume == true,
              let uuid = v.volumeUUIDString, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// Identificador curto e estável de uma cópia (nome do registro, âncora no relatório). Hash do id
    /// inteiro: o começo do id é o hash dos arquivos, igual em cartões gêmeos.
    public static func shortID(_ offloadId: String) -> String {
        String(String(format: "%016llx", XXHash64.hash(Data(offloadId.utf8))).prefix(8))
    }
}
