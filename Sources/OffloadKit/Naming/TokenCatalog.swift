/// Metadado humano de um token, pro construtor de peças mostrar rótulo + ícone + descrição (o que faz).
public struct TokenInfo: Equatable, Sendable {
    public let name: String
    public let label: String
    public let category: String
    public let systemImage: String
    public let description: String
    public init(name: String, label: String, category: String, systemImage: String, description: String) {
        self.name = name; self.label = label; self.category = category
        self.systemImage = systemImage; self.description = description
    }
}

public enum TokenCatalog {
    public static let all: [TokenInfo] = [
        .init(name: "projeto", label: "Projeto", category: "Projeto", systemImage: "folder",
              description: "O nome do projeto, que vira a pasta principal."),
        .init(name: "tipo", label: "Tipo de mídia", category: "Arquivo", systemImage: "photo.on.rectangle",
              description: "Foto, Vídeo, Áudio ou Cinema, conforme o arquivo."),
        .init(name: "nome_original", label: "Nome original", category: "Arquivo", systemImage: "doc",
              description: "O nome que o arquivo já tinha no cartão."),
        .init(name: "ext", label: "Extensão", category: "Arquivo", systemImage: "doc.badge.gearshape",
              description: "A extensão do arquivo (jpg, mov, wav…)."),
        .init(name: "camera", label: "Câmera", category: "Origem", systemImage: "camera",
              description: "O nome da câmera (CAM A, CAM 1…), escolhido em cada cartão."),
        .init(name: "cartao", label: "Cartão", category: "Origem", systemImage: "sdcard",
              description: "O nome do cartão ou disco de origem."),
        .init(name: "lote", label: "Lote", category: "Origem", systemImage: "rectangle.stack",
              description: "Numera 1, 2, 3… a cada vez que você retoma a descarga do mesmo cartão."),
        .init(name: "pasta_origem", label: "Pasta no cartão", category: "Origem", systemImage: "folder",
              description: "A pasta onde o arquivo estava no cartão (CLIP, 100CANON…)."),
        .init(name: "contador", label: "Número", category: "Contador", systemImage: "number",
              description: "Número sequencial (001, 002…) na ordem da cópia."),
        .init(name: "data", label: "Data", category: "Data e hora", systemImage: "calendar",
              description: "A data em que o arquivo foi capturado."),
        .init(name: "hora", label: "Hora", category: "Data e hora", systemImage: "clock",
              description: "A hora em que o arquivo foi capturado."),
        .init(name: "turno", label: "Turno", category: "Data e hora", systemImage: "sun.horizon",
              description: "Manhã, Tarde ou Noite, pela hora do arquivo."),
        // granulares: pra montar QUALQUER formato com as peças (sem ano, ordem diferente, etc.)
        .init(name: "dia", label: "Dia", category: "Partes da data", systemImage: "calendar",
              description: "O dia do mês (28)."),
        .init(name: "dia_semana", label: "Dia da semana", category: "Partes da data", systemImage: "calendar",
              description: "O dia da semana por extenso (Segunda)."),
        .init(name: "dia_semana_abrev", label: "Dia da semana curto", category: "Partes da data", systemImage: "calendar",
              description: "O dia da semana abreviado (Seg)."),
        .init(name: "mes", label: "Mês", category: "Partes da data", systemImage: "calendar",
              description: "O mês em número (05)."),
        .init(name: "mes_abrev", label: "Mês curto", category: "Partes da data", systemImage: "calendar",
              description: "O mês abreviado (Mai)."),
        .init(name: "mes_nome", label: "Mês por extenso", category: "Partes da data", systemImage: "calendar",
              description: "O mês por extenso (Maio)."),
        .init(name: "ano", label: "Ano", category: "Partes da data", systemImage: "calendar",
              description: "O ano com 4 dígitos (2026)."),
        .init(name: "ano2", label: "Ano curto", category: "Partes da data", systemImage: "calendar",
              description: "O ano com 2 dígitos (26)."),
        .init(name: "horas", label: "Horas", category: "Partes da data", systemImage: "clock",
              description: "As horas sozinhas (17)."),
        .init(name: "minutos", label: "Minutos", category: "Partes da data", systemImage: "clock",
              description: "Os minutos sozinhos (26)."),
        .init(name: "segundos", label: "Segundos", category: "Partes da data", systemImage: "clock",
              description: "Os segundos sozinhos (40)."),
    ]
    /// Resolve apelidos antigos (`evento` → `projeto`) pra modelos salvos antes da 1.0 mostrarem a peça certa.
    public static func info(for token: String) -> TokenInfo? {
        let name = NameBuilder.tokenAliases[token] ?? token
        return all.first { $0.name == name }
    }

    /// Ordem das categorias no menu de adicionar peça.
    public static let categoryOrder = ["Projeto", "Data e hora", "Partes da data", "Origem", "Arquivo", "Contador"]
}
