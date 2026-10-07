import Foundation
import ImageIO
import AVFoundation

/// Lê marca/modelo da câmera do metadado do próprio arquivo: EXIF (TIFF) para fotos, metadado comum
/// (QuickTime) para vídeos. Usado pra autopreencher o token {camera} — o valor continua editável à mão.
/// Formatos de cinema RAW (r3d/braw/mxf…) não trazem isso via frameworks do sistema → devolve nil.
public enum CameraMetadata {
    /// Nome provisório antigo (antes da 1.0). Registros com ele não dizem nada sobre o cartão, então telas
    /// e relatório não mostram.
    public static let placeholder = "Cam01"

    /// Nome padrão da câmera de um cartão: "CAM A", "CAM B"… a primeira letra livre entre os cartões.
    public static func defaultName(avoiding used: Set<String>) -> String {
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" where !used.contains("CAM \(letter)") { return "CAM \(letter)" }
        return "CAM A"
    }

    /// A câmera vale ser mostrada? (não vazia e não o nome provisório)
    public static func isMeaningful(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != placeholder
    }

    /// Câmera lida de um arquivo, conforme o tipo. nil quando o formato não traz o dado.
    public static func cameraModel(at url: URL, type: FileType) async -> String? {
        switch type {
        case .photo: return photoCameraModel(at: url)
        case .video: return await videoCameraModel(at: url)
        default: return nil   // cinema/áudio/sidecar/desconhecido: sem leitura de marca/modelo
        }
    }

    /// Primeira câmera detectável percorrendo os arquivos em ordem (a maioria dos cartões é de uma
    /// câmera só). Para no primeiro que devolver algo, com um teto pra não varrer o cartão inteiro.
    public static func firstCameraModel(in files: [MediaFile], limit: Int = 12) async -> String? {
        for file in files.prefix(limit) {
            if let m = await cameraModel(at: file.sourceURL, type: file.type) { return m }
        }
        return nil
    }

    // MARK: - Foto (ImageIO, lê só o cabeçalho)

    static func photoCameraModel(at url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return nil }
        return compose(make: tiff[kCGImagePropertyTIFFMake] as? String,
                       model: tiff[kCGImagePropertyTIFFModel] as? String)
    }

    // MARK: - Vídeo (AVFoundation, metadado comum/QuickTime)

    static func videoCameraModel(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata),
           let m = compose(make: commonString(items, .commonKeyMake), model: commonString(items, .commonKeyModel)) {
            return m
        }
        // Sony (XAVC) e outras câmeras de vídeo não gravam marca/modelo no MP4: vai no XML ao lado do clipe
        return sidecarCameraModel(for: url)
    }

    // MARK: - XML ao lado do clipe

    /// `<Device manufacturer="Sony" modelName="ILME-FX30"/>` no XML do clipe (C0001M01.XML, C0001.XML).
    static func sidecarCameraModel(for url: URL) -> String? {
        let base = url.deletingPathExtension()
        let candidates = [base.lastPathComponent + "M01.XML", base.lastPathComponent + ".XML", base.lastPathComponent + ".xml"]
            .map { base.deletingLastPathComponent().appendingPathComponent($0) }
        for xml in candidates {
            guard let data = try? Data(contentsOf: xml, options: .mappedIfSafe), data.count < 512_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            if let m = deviceModel(inXML: text) { return m }
        }
        return nil
    }

    /// Marca e modelo da tag `<Device …>` de um XML de clipe (atributos em qualquer ordem).
    static func deviceModel(inXML text: String) -> String? {
        guard let r = text.range(of: #"<Device\b[^>]*>"#, options: .regularExpression) else { return nil }
        let tag = String(text[r])
        func attr(_ name: String) -> String? {
            guard let a = tag.range(of: name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
            return String(tag[a].dropFirst(name.count + 2).dropLast())
        }
        return compose(make: attr("manufacturer"), model: attr("modelName"))
    }

    private static func commonString(_ items: [AVMetadataItem], _ key: AVMetadataKey) -> String? {
        guard let id = AVMetadataItem.identifier(forKey: key, keySpace: .common) else { return nil }
        return AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first?.stringValue
    }

    // MARK: - Nome curto

    /// Nome curto como quem filma fala: "SONY ILME-FX30" → "FX30", "ILCE-7SM3" → "A7S III",
    /// "Panasonic DC-S5M2" → "S5II", "Canon EOS R5" → "R5", "NIKON Z 6_2" → "Z6 II". Regras por padrão de
    /// nome de cada marca, sem catálogo: modelo que não casa com nenhuma regra fica como veio, sem a marca.
    public static func shortName(_ full: String) -> String {
        var s = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        let panasonic = lower.contains("panasonic") || lower.contains("lumix")
        let brands = ["nikon corporation", "om digital solutions", "blackmagic design", "sony", "canon", "nikon",
                      "panasonic", "lumix", "fujifilm", "olympus", "blackmagic", "apple", "ricoh", "leica", "sigma"]
        for b in brands where s.lowercased().hasPrefix(b + " ") { s = String(s.dropFirst(b.count + 1)); break }
        if s.hasPrefix("EOS ") { s = String(s.dropFirst(4)) }
        var sonyAlpha = false
        for (prefix, keepA) in [("ILCE-", true), ("ILME-", false), ("DSC-", false), ("PXW-", false), ("HXR-", false),
                                ("DC-", false), ("DMC-", false)] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)); sonyAlpha = keepA; break
        }
        if sonyAlpha { s = "A" + s }
        // Nikon: "Z 6_2" → "Z6 II"
        if let r = s.range(of: #"^Z (\d)"#, options: .regularExpression) { s.replaceSubrange(r, with: "Z" + s[r].dropFirst(2)) }
        if let r = s.range(of: #"_(\d)$"#, options: .regularExpression), let n = Int(s[r].dropFirst()), let roman = roman(n) {
            s.replaceSubrange(r, with: " " + roman)
        }
        // geração no fim: Sony "A7SM3" → "A7S III"; Panasonic "S5M2" → "S5II" (como a marca escreve)
        if let r = s.range(of: #"(?<=[0-9A-Z])M(\d)X?$"#, options: .regularExpression) {
            let tail = s[r]
            let n = Int(String(tail.dropFirst().prefix(1))) ?? 0
            if let roman = roman(n) {
                let x = tail.hasSuffix("X") ? "X" : ""
                s.replaceSubrange(r, with: (panasonic ? "" : " ") + roman + x)
            }
        }
        return s.isEmpty ? full : s
    }

    private static func roman(_ n: Int) -> String? {
        [2: "II", 3: "III", 4: "IV", 5: "V", 6: "VI", 7: "VII", 8: "VIII"][n]
    }

    // MARK: - Composição

    /// Junta marca + modelo num rótulo legível, sem duplicar a marca quando o modelo já a contém
    /// (Canon + "Canon EOS R5" → "Canon EOS R5"). Mantém os valores VERBATIM (não normaliza caixa:
    /// "DJI"/"GoPro" quebrariam com title-case). Devolve nil quando nenhum dos dois existe.
    static func compose(make rawMake: String?, model rawModel: String?) -> String? {
        let make = rawMake?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mk = (make?.isEmpty == false) ? make! : nil
        let md = (model?.isEmpty == false) ? model! : nil
        guard let md else { return mk }
        guard let mk else { return md }
        let firstWord = String(mk.split(separator: " ").first ?? Substring(mk))
        if md.range(of: firstWord, options: .caseInsensitive) != nil { return md }
        return "\(mk) \(md)"
    }
}
