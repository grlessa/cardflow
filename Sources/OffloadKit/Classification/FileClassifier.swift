import Foundation

public struct FileClassifier {
    private let preset: Preset
    private static let junkNames: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]
    // Arquivos de gestão de câmera/cartão (Sony/AVCHD) — inúteis, não são mídia.
    private static let junkExtensions: Set<String> = ["bnp", "inp", "int", "ind", "bin", "modd", "moff", "dat", "tdt", "tid"]

    // Formatos de cinema (RAW/MXF). Tipados como .cinema independentemente do preset: a
    // preservação da árvore é mecanismo de segurança do motor, não preferência do usuário.
    private static let cinemaExtensions: Set<String> = ["r3d", "braw", "crm", "ari", "arx", "mxf"]

    // Pastas que contêm EXCLUSIVAMENTE thumbnail/preview de vídeo (sem mídia real junto) — pesquisado
    // por marca: Sony THMBNL (PRIVATE/M4ROOT/THMBNL, .jpg), AVCHD AVCHDTN (.tdt/.tid). Panasonic P2
    // (CONTENTS/ICON, .bmp) é casado por caminho (abaixo) porque "icon" é nome genérico.
    // ⚠️ Canon/Nikon/Fuji NÃO entram aqui: guardam o .THM JUNTO da mídia no DCIM → tratados por extensão.
    private static let thumbnailFolders: Set<String> = ["thmbnl", "avchdtn"]

    public init(preset: Preset) { self.preset = preset }

    public func classify(fileName: String) -> FileType {
        let lowerName = fileName.lowercased()
        if Self.junkNames.contains(lowerName) { return .junk }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .unknown }

        if Self.cinemaExtensions.contains(ext) { return .cinema }
        if preset.videoExtensions.contains(ext) { return .video }
        if preset.photoExtensions.contains(ext) { return .photo }
        if !preset.audioExtensions.isEmpty, preset.audioExtensions.contains(ext) { return .audio }
        if preset.sidecarExtensions.contains(ext) { return .sidecar }
        if Self.junkExtensions.contains(ext) { return .junk }
        return .unknown
    }

    /// Classificação ciente do caminho — usada pelo scanner. Igual à por nome, mas rebaixa a lixo
    /// arquivos em pasta EXCLUSIVAMENTE de thumbnail (determinístico, sem heurística de tamanho —
    /// que dropava foto real pequena solta na raiz). `size` mantido pra futuras regras seguras.
    public func classify(relPath: String, size: Int64) -> FileType {
        if Self.inThumbnailFolder(relPath) { return .junk }
        return classify(fileName: (relPath as NSString).lastPathComponent)
    }

    /// O arquivo está numa pasta dedicada a thumbnail de vídeo (sem mídia real junto)?
    static func inThumbnailFolder(_ relPath: String) -> Bool {
        let folders = relPath.lowercased().split(separator: "/").dropLast().map(String.init)
        if folders.contains(where: { thumbnailFolders.contains($0) }) { return true }
        // Panasonic P2: par consecutivo "contents/icon" (match por componente, não substring).
        for i in folders.indices.dropLast() where folders[i] == "contents" && folders[i + 1] == "icon" {
            return true
        }
        return false
    }
}
