import Foundation

public struct FileClassifier {
    private static let junkNames: Set<String> = [".ds_store", "thumbs.db", "desktop.ini"]
    // Arquivos de gestão de câmera/cartão (Sony/AVCHD) — inúteis, não são mídia.
    private static let junkExtensions: Set<String> = ["bnp", "inp", "int", "ind", "bin", "modd", "moff", "dat", "tdt", "tid"]

    // Formatos de cinema (RAW/MXF). Tipados como .cinema independentemente do preset: a
    // preservação da árvore é mecanismo de segurança do motor, não preferência do usuário.
    private static let cinemaExtensions: Set<String> = ["r3d", "braw", "crm", "ari", "arx", "mxf"]

    // Foto / vídeo / áudio / sidecar reconhecidos NATIVAMENTE pela extensão — igual ao cinema. "Isto é
    // um .wav/.jpg/.mp4" é um FATO do formato, não preferência do usuário: o APP define o que é cada
    // tipo, não o preset. O preset só decide se COPIA (seletor de mídia) e como ORGANIZA (pastas).
    // Modelos antigos guardam listas de extensão no .cfp, mas são IGNORADAS aqui (não afetam o novo).
    private static let nativePhotoExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "hif", "webp", "insp",
        // RAW de câmera
        "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "raf", "rw2", "rwl", "orf", "dng",
        "gpr", "pef", "srw", "x3f", "3fr", "mef", "mos", "kdc", "dcr", "erf", "mrw", "iiq",
    ]
    private static let nativeVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts", "m2t", "ts", "avi", "mkv", "webm",
        "mpg", "mpeg", "mpe", "wmv", "flv", "vob", "3gp", "3g2", "insv", "360", "dv", "ogv",
    ]
    private static let nativeAudioExtensions: Set<String> = [
        "wav", "wave", "bwf", "w64", "rf64", "aif", "aiff", "aifc", "caf", "alac",
        "flac", "ape", "wv", "mp1", "mp2", "mp3", "mpga", "m1a",
        "aac", "m4a", "m4b", "m4p", "m4r", "3ga", "f4a",
        "ogg", "oga", "opus", "wma", "amr", "awb", "au", "snd",
        "ac3", "a52", "eac3", "dts", "dtshd", "dsf", "dff", "at3", "aa", "aax",
    ]
    private static let nativeSidecarExtensions: Set<String> = [
        "xml", "thm", "xmp", "bim", "cube", "aae",   // metadados / thumbnail / LUT / edições de iPhone
    ]

    // Pastas que contêm EXCLUSIVAMENTE thumbnail/preview de vídeo (sem mídia real junto) — pesquisado
    // por marca: Sony THMBNL (PRIVATE/M4ROOT/THMBNL, .jpg), AVCHD AVCHDTN (.tdt/.tid). Panasonic P2
    // (CONTENTS/ICON, .bmp) é casado por caminho (abaixo) porque "icon" é nome genérico.
    // ⚠️ Canon/Nikon/Fuji NÃO entram aqui: guardam o .THM JUNTO da mídia no DCIM → tratados por extensão.
    private static let thumbnailFolders: Set<String> = ["thmbnl", "avchdtn"]

    // O preset é recebido por compat de chamada, mas NÃO é usado: a classificação é 100% nativa.
    public init(preset: Preset = .factoryDefault) {}

    public func classify(fileName: String) -> FileType {
        let lowerName = fileName.lowercased()
        if Self.junkNames.contains(lowerName) { return .junk }

        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty { return .unknown }

        if Self.cinemaExtensions.contains(ext) { return .cinema }
        if Self.nativeVideoExtensions.contains(ext) { return .video }
        if Self.nativePhotoExtensions.contains(ext) { return .photo }
        if Self.nativeAudioExtensions.contains(ext) { return .audio }
        if Self.nativeSidecarExtensions.contains(ext) { return .sidecar }
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
