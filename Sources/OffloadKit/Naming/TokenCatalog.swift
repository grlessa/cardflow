/// Metadado humano de um token, pro construtor de peças mostrar rótulo + ícone em vez de "{token}".
public struct TokenInfo: Equatable, Sendable {
    public let name: String
    public let label: String
    public let category: String
    public let systemImage: String
    public init(name: String, label: String, category: String, systemImage: String) {
        self.name = name; self.label = label; self.category = category; self.systemImage = systemImage
    }
}

public enum TokenCatalog {
    public static let all: [TokenInfo] = [
        .init(name: "evento", label: "Evento", category: "Evento", systemImage: "tag"),
        .init(name: "tipo", label: "Tipo de mídia", category: "Arquivo", systemImage: "photo.on.rectangle"),
        .init(name: "nome_original", label: "Nome original", category: "Arquivo", systemImage: "doc"),
        .init(name: "ext", label: "Extensão", category: "Arquivo", systemImage: "doc.badge.gearshape"),
        .init(name: "camera", label: "Câmera", category: "Origem", systemImage: "camera"),
        .init(name: "cartao", label: "Cartão", category: "Origem", systemImage: "sdcard"),
        .init(name: "pasta_origem", label: "Pasta de origem", category: "Origem", systemImage: "folder"),
        .init(name: "contador", label: "Nº sequencial", category: "Contador", systemImage: "number"),
        .init(name: "data", label: "Data", category: "Data e hora", systemImage: "calendar"),
        .init(name: "ano", label: "Ano (2026)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "ano2", label: "Ano (26)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "mes", label: "Mês (05)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "mes_abrev", label: "Mês abrev. (Mai)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "mes_nome", label: "Mês nome (Maio)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "dia", label: "Dia (28)", category: "Data e hora", systemImage: "calendar"),
        .init(name: "horas", label: "Horas (17)", category: "Data e hora", systemImage: "clock"),
        .init(name: "minutos", label: "Minutos (26)", category: "Data e hora", systemImage: "clock"),
        .init(name: "segundos", label: "Segundos (40)", category: "Data e hora", systemImage: "clock"),
        .init(name: "hora", label: "Hora (172640)", category: "Data e hora", systemImage: "clock"),
    ]
    public static func info(for token: String) -> TokenInfo? { all.first { $0.name == token } }

    /// Ordem das categorias no menu de adicionar peça.
    public static let categoryOrder = ["Evento", "Data e hora", "Origem", "Arquivo", "Contador"]
}
