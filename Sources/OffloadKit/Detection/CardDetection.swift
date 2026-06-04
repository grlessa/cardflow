import Foundation

public struct ExternalVolume: Equatable, Identifiable, Sendable {
    public var url: URL
    public var name: String
    public var isRemovable: Bool
    public var isInternal: Bool
    public var totalBytes: Int64?        // capacidade do volume (pra ordenar destinos por tamanho)
    public var physicalDeviceID: String? // disco físico (whole-disk BSD, ex.: "disk4") — backup ≠ mesmo disco
    public var volumeUUID: String?       // identidade estável do volume (lembrar destino entre sessões)
    public var id: String { url.path }
    public init(url: URL, name: String, isRemovable: Bool, isInternal: Bool,
                totalBytes: Int64? = nil, physicalDeviceID: String? = nil, volumeUUID: String? = nil) {
        self.url = url; self.name = name; self.isRemovable = isRemovable
        self.isInternal = isInternal; self.totalBytes = totalBytes
        self.physicalDeviceID = physicalDeviceID; self.volumeUUID = volumeUUID
    }
}

public enum CardDetection {
    /// Pastas-marcador de câmera de nome exato na raiz — só as fortemente específicas, pra não dar
    /// falso-positivo em disco de trabalho. PRIVATE cobre Sony M4ROOT/XDROOT e Panasonic AVCHD;
    /// AVF_INFO (Sony/Panasonic), MP_ROOT (Sony MP4), CRM (Canon Cinema RAW Light). Cinema EOS XF /
    /// P2 (CONTENTS) é tratado à parte (exige pasta de clipe dentro).
    private static let cameraMarkers = ["DCIM", "PRIVATE", "AVF_INFO", "MP_ROOT", "CRM"]

    /// Extensões que, SOLTAS na raiz, indicam uma FONTE marker-less (gravador, Blackmagic, cinema,
    /// camcorder). Genéricas (jpg/mp4/mov/mp3) ficam de FORA: aparecem em disco de trabalho e dariam
    /// falso-positivo — cartão genérico de câmera tem DCIM (pego pelos marcadores).
    private static let looseSourceExtensions: Set<String> = [
        "wav", "m4a", "aac", "flac", "aiff", "aif",   // gravadores de áudio (mp3 fora: genérico demais)
        "braw", "r3d", "mxf", "mts", "m2ts",          // cinema / camcorder
    ]

    /// É fonte de mídia se for removível E (pasta-marcador OU CONTENTS-com-clipe OU RED OU extensão
    /// de fonte solta na raiz). (Leitor de SD embutido reporta interno → não filtra por isso.)
    public static func isCard(_ vol: ExternalVolume) -> Bool {
        guard vol.isRemovable else { return false }
        let fm = FileManager.default
        // 1) pasta-marcador de câmera de nome exato na raiz
        if cameraMarkers.contains(where: { fm.fileExists(atPath: vol.url.appendingPathComponent($0).path) }) {
            return true
        }
        // 2) Cinema EOS XF / Panasonic P2: CONTENTS com pasta de clipe (CLIP/CLIPS/CLIPS001…), não DCIM.
        let contents = vol.url.appendingPathComponent("CONTENTS")
        if let items = try? fm.contentsOfDirectory(atPath: contents.path),
           items.contains(where: { name in
               // exige PASTA de clipe (CLIP/CLIPS/CLIPS001…), não um ARQUIVO qualquer chamado CLIP* (ex.: CLIPBOARD.txt)
               guard name.uppercased().hasPrefix("CLIP") else { return false }
               var isDir: ObjCBool = false
               return fm.fileExists(atPath: contents.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
           }) {
            return true
        }
        // 3) marker-less: RED (pastas .RDM/.RDC) ou extensão de FONTE solta na raiz (gravador/cinema).
        guard let root = try? fm.contentsOfDirectory(atPath: vol.url.path) else { return false }
        for name in root {
            if name.hasPrefix(".") { continue }   // ignora lixo do macOS (.Spotlight-V100, .fseventsd, .Trashes)
            let upper = name.uppercased()
            if upper.hasSuffix(".RDM") || upper.hasSuffix(".RDC") { return true }
            if looseSourceExtensions.contains((name as NSString).pathExtension.lowercased()) { return true }
        }
        return false
    }
    public static func cards(from volumes: [ExternalVolume]) -> [ExternalVolume] {
        volumes.filter { isCard($0) }
    }
    public static func destinations(from volumes: [ExternalVolume]) -> [ExternalVolume] {
        volumes.filter { !isCard($0) }
    }
}
