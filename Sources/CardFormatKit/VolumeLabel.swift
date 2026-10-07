import Foundation

/// O cartão mantém o nome atual (decisão do dono); aqui só o adequamos ao que cada sistema aceita.
public enum VolumeLabel {
    private static let forbiddenCommon = Set("\"*/:<>?\\|")
    private static let forbiddenFAT = Set(".+,;=[]")

    /// exFAT: até 11 unidades UTF-16, sem caracteres proibidos nem de controle.
    public static func exfat(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
            .filter { !forbiddenCommon.contains($0) && !($0.asciiValue.map { $0 < 0x20 } ?? false) }
        var out = ""
        for ch in cleaned {
            if (out + String(ch)).utf16.count > 11 { break }
            out.append(ch)
        }
        return out
    }

    /// FAT: ASCII maiúsculo, até 11 bytes; não-ASCII vira "_".
    public static func fat(_ s: String) -> String {
        let up = s.trimmingCharacters(in: .whitespaces).uppercased()
        var out = ""
        for ch in up {
            guard !forbiddenCommon.contains(ch), !forbiddenFAT.contains(ch) else { continue }
            let c: Character = (ch.asciiValue.map { $0 >= 0x20 && $0 < 0x7F } ?? false) ? ch : "_"
            if out.count == 11 { break }
            out.append(c)
        }
        return out
    }
}
