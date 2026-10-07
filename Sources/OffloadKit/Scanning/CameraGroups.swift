import Foundation

/// Grupo de origem de um arquivo no cartão: a pasta onde ele está. Cada câmera grava na sua (DCIM/100GOPRO,
/// DCIM/100CANON, PRIVATE/M4ROOT/CLIP), então um cartão que passou por várias câmeras vira vários grupos.
/// Pacote de cinema (preservado) é um grupo só, pela raiz do pacote. Serve pra dar a cada arquivo o nome
/// da câmera dele e pra deixar uma câmera inteira de fora da cópia.
public enum CameraGroups {
    public static func key(for f: MediaFile) -> String {
        let parts = f.relPath.split(separator: "/").map(String.init)
        if f.preserve { return parts.prefix(2).joined(separator: "/") }
        return parts.dropLast().joined(separator: "/")
    }

    /// Câmera de cada grupo (nome completo lido do arquivo, ex. "Sony ILME-FX30"). Lê até `triesPerGroup`
    /// arquivos de foto/vídeo por pasta; grupo sem leitura (áudio, RAW de cinema) fica de fora.
    public static func detect(in files: [MediaFile], triesPerGroup: Int = 3) async -> [String: String] {
        let media = files.filter { !$0.preserve && ($0.type == .photo || $0.type == .video) }
        var out: [String: String] = [:]
        for (k, fs) in Dictionary(grouping: media, by: key(for:)) {
            for f in fs.prefix(triesPerGroup) {
                if let m = await CameraMetadata.cameraModel(at: f.sourceURL, type: f.type) { out[k] = m; break }
            }
            if out[k] == nil, let brand = brandHint(forGroup: k) { out[k] = brand }
        }
        return out
    }

    /// Marca pelo nome da pasta DCF quando o arquivo não diz a câmera (GoPro, por exemplo, guarda o modelo
    /// num formato próprio): "DCIM/100GOPRO" → "GoPro". Só a marca, sem adivinhar modelo.
    static func brandHint(forGroup key: String) -> String? {
        guard let folder = key.split(separator: "/").last.map({ String($0).uppercased() }) else { return nil }
        let hints: [(String, String)] = [("GOPRO", "GoPro"), ("CANON", "Canon"), ("MSDCF", "Sony"), ("_PANA", "Panasonic"),
                                         ("NIKON", "Nikon"), ("_FUJI", "Fujifilm"), ("OLYMP", "Olympus"), ("MEDIA", "DJI"),
                                         ("RICOH", "Ricoh"), ("LEICA", "Leica")]
        return hints.first { folder.hasSuffix($0.0) }?.1
    }
}
