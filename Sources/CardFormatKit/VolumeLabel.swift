import Foundation

/// O cartão mantém o nome atual (decisão do dono); aqui só o adequamos ao que cada sistema aceita.
public enum VolumeLabel {
    private static let forbiddenCommonScalars = Set("\"*/:<>?\\|".unicodeScalars)
    private static let forbiddenFATScalars = Set(".+,;=[]".unicodeScalars)

    /// exFAT: até 11 unidades UTF-16, sem caracteres proibidos nem de controle.
    public static func exfat(_ s: String) -> String {
        let filtered = String(String.UnicodeScalarView(s.unicodeScalars.filter { sc in
            sc.value >= 0x20 && sc.value != 0x7F && !forbiddenCommonScalars.contains(sc)
        })).trimmingCharacters(in: .whitespaces)
        var out = ""
        for ch in filtered {
            if (out + String(ch)).utf16.count > 11 { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// FAT: ASCII maiúsculo, até 11 bytes; não-ASCII vira "_".
    public static func fat(_ s: String) -> String {
        let up = s.uppercased()
        var buf = ""
        for sc in up.unicodeScalars {
            if sc.value < 0x20 || sc.value == 0x7F { continue }
            if forbiddenCommonScalars.contains(sc) || forbiddenFATScalars.contains(sc) { continue }
            if sc.value < 0x7F { buf.unicodeScalars.append(sc) } else { buf.append("_") }
        }
        let trimmed = buf.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(11)).trimmingCharacters(in: .whitespaces)
    }
}
