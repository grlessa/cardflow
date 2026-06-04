/// Categoria de um arquivo do cartão.
public enum FileType: String, Codable, Sendable, CaseIterable {
    case photo
    case video
    case audio
    case cinema    // formato de cinema preservado verbatim (r3d/braw/mxf/crm/ari/arx)
    case sidecar
    case junk      // lixo de sistema (.DS_Store etc.) — ignorado em silêncio
    case unknown   // não reconhecido — vai pra rede de segurança
}
