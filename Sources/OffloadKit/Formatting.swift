import Foundation

/// Formatação compartilhada entre o app e a CLI — antes `humanBytes` estava duplicado e DIVERGENTE
/// (app em base 1000, CLI em base 1024), mostrando tamanhos diferentes pra mesma mídia.
public enum Format {
    /// Tamanho legível em base DECIMAL (1000), igual ao Finder e ao Ajustes do macOS — pra o número
    /// bater com o que o usuário vê no disco. O binário (1024) mostrava 70,8 onde o Finder mostra 76,0.
    public static func humanBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes); var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    /// Tempo legível em pt-BR: "45 s", "17 min 12 s", "1 h 17 min".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60, sec = s % 60
        if m < 60 { return sec == 0 ? "\(m) min" : "\(m) min \(sec) s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
    }
}
