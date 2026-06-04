import Foundation

public enum NamingError: Error, Equatable {
    case unknownToken(String)
    case unknownModifier(String)
    case pathTraversal(String)   // template tenta escapar da pasta de destino (../, /abs, ~)
}

extension NamingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownToken(let t):
            return "O preset usa um campo desconhecido: “\(t)”. Revise a estrutura de pastas ou o padrão de nome."
        case .unknownModifier(let m):
            return "O preset usa um modificador desconhecido: “\(m)”."
        case .pathTraversal:
            return "A estrutura de pastas do preset é inválida — ela não pode sair da pasta de destino."
        }
    }
}

public struct NamingContext {
    public var camera: String
    public var counter: Int        // índice 1-based da execução
    public var cardName: String
    public var sessionValues: [String: String]
    public init(camera: String, counter: Int, cardName: String = "", sessionValues: [String: String] = [:]) {
        self.camera = camera; self.counter = counter; self.cardName = cardName; self.sessionValues = sessionValues
    }
}

public struct NameBuilder {
    private let preset: Preset
    let timeZone: TimeZone

    public init(preset: Preset, timeZone: TimeZone = .current) {
        self.preset = preset; self.timeZone = timeZone
    }

    public static let knownTokens: Set<String> = [
        "evento", "tipo", "camera", "cartao", "nome_original", "ext", "pasta_origem", "contador",
        "ano", "ano2", "mes", "mes_abrev", "mes_nome", "dia", "horas", "minutos", "segundos", "data", "hora",
    ]
    public static let knownModifiers: Set<String> = ["maiuscula", "minuscula"]

    /// Ordem de exibição dos tokens no picker do editor (mais comuns primeiro).
    /// `Set(tokenOrder) == knownTokens` é garantido por teste — não deixar um token de fora.
    public static let tokenOrder: [String] = [
        "evento", "tipo", "camera", "cartao",
        "nome_original", "ext", "contador", "pasta_origem",
        "ano", "ano2", "mes", "mes_abrev", "mes_nome", "dia",
        "horas", "minutos", "segundos", "data", "hora",
    ]

    private func tipoFolder(for type: FileType) -> String {
        switch type {
        case .photo: return "FOTO"
        case .video: return "VIDEO"
        case .audio: return "AUDIO"
        default: return "OUTROS"
        }
    }

    private func df(_ format: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    private func month(_ date: Date, abbreviated: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: preset.locale)
        f.timeZone = timeZone
        f.dateFormat = abbreviated ? "MMM" : "MMMM"
        let raw = f.string(from: date).replacingOccurrences(of: ".", with: "")
        return raw.isEmpty ? raw : raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private func baseValue(_ name: String, file: MediaFile, ctx: NamingContext) -> String? {
        let last = (file.relPath as NSString).lastPathComponent
        switch name {
        case "evento": return preset.evento
        case "tipo": return tipoFolder(for: file.type)
        case "camera": return ctx.camera
        case "cartao": return ctx.cardName
        case "nome_original": return (last as NSString).deletingPathExtension
        case "ext": return (file.relPath as NSString).pathExtension
        case "pasta_origem": return ((file.relPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        case "contador":
            let n = preset.rename.counterStart + (ctx.counter - 1) * preset.rename.counterStep
            return String(format: "%0\(preset.rename.counterPadding)d", n)
        case "ano": return df("yyyy", file.captureDate)
        case "ano2": return df("yy", file.captureDate)
        case "mes": return df("MM", file.captureDate)
        case "mes_abrev": return month(file.captureDate, abbreviated: true)
        case "mes_nome": return month(file.captureDate, abbreviated: false)
        case "dia": return df("dd", file.captureDate)
        case "horas": return df("HH", file.captureDate)
        case "minutos": return df("mm", file.captureDate)
        case "segundos": return df("ss", file.captureDate)
        case "data": return df(preset.dateFormat, file.captureDate)
        case "hora": return df("HHmmss", file.captureDate)
        default:
            if let v = ctx.sessionValues[name] { return v }
            if preset.sessionFields.contains(where: { $0.key == name }) { return "" }
            return nil
        }
    }

    private func resolveToken(_ inner: String, file: MediaFile, ctx: NamingContext) throws -> String {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        guard var value = baseValue(name, file: file, ctx: ctx) else { throw NamingError.unknownToken(name) }
        for mod in parts.dropFirst() {
            switch mod {
            case "maiuscula": value = value.uppercased()
            case "minuscula": value = value.lowercased()
            default: throw NamingError.unknownModifier(mod)
            }
        }
        return Self.sanitizePathComponent(value)
    }

    /// Limpa o VALOR de um token de caracteres que viram separador de path no macOS
    /// ("/" e o ":" legado), pra um "Culto 09/06" ou um {data} com barras não criar
    /// subpasta acidental. Os "/" literais do template (estrutura de pastas) não passam por aqui.
    /// Também neutraliza um valor que seja exatamente "." ou ".." — senão um {evento}="…"
    /// viraria um componente de path de travessia (subir de pasta).
    public static func sanitizePathComponent(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-")
                       .replacingOccurrences(of: ":", with: "-")
                       .replacingOccurrences(of: "\0", with: "")
        if cleaned == "." { return "_" }
        if cleaned == ".." { return "__" }
        return cleaned
    }

    /// Rejeita um template cuja PARTE LITERAL permitiria escapar da pasta de destino
    /// (path traversal): caminho absoluto ("/…"), home ("~…") ou um segmento ".." literal.
    /// Os VALORES de token já são saneados em `sanitizePathComponent` (não viram "/" nem ".."),
    /// então aqui só importam os literais que o usuário/preset escreveu fora dos `{…}`.
    public static func validateNoTraversal(in template: String) throws {
        if template.hasPrefix("/") || template.hasPrefix("~") {
            throw NamingError.pathTraversal(template)
        }
        // Esqueleto literal: troca cada {token} por uma sentinela (não-vazia, sem "/")
        // pra checar os segmentos de pasta sem confundir com o conteúdo dos tokens.
        var skeleton = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                skeleton.append("X")
                i = template.index(after: close)
            } else {
                skeleton.append(template[i]); i = template.index(after: i)
            }
        }
        for seg in skeleton.split(separator: "/", omittingEmptySubsequences: false) where seg == ".." {
            throw NamingError.pathTraversal(template)
        }
    }

    private func render(_ template: String, file: MediaFile, ctx: NamingContext) throws -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = String(template[template.index(after: i)..<close])
                out += try resolveToken(inner, file: file, ctx: ctx)
                i = template.index(after: close)
            } else {
                out.append(template[i])
                i = template.index(after: i)
            }
        }
        return out
    }

    public func relativeDestination(for file: MediaFile, context ctx: NamingContext) throws -> String {
        let folder = try render(preset.folderStructure, file: file, ctx: ctx)
        let fileName: String
        if preset.rename.enabled {
            let stem = try render(preset.rename.template, file: file, ctx: ctx)
            let ext = (file.relPath as NSString).pathExtension
            fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
        } else {
            fileName = (file.relPath as NSString).lastPathComponent
        }
        return folder + "/" + fileName
    }

    /// Compat com o Plano 1 (testes/serviço que passam camera+counter direto).
    public func relativeDestination(for file: MediaFile, camera: String, counter: Int) throws -> String {
        try relativeDestination(for: file, context: NamingContext(camera: camera, counter: counter))
    }

    /// Prévia ao vivo do nome (pasta/arquivo) pro editor de preset: nunca lança —
    /// devolve `.failure` quando o template tem token/modificador inválido, pra UI mostrar o erro.
    public func preview(for file: MediaFile = .previewSample,
                        context: NamingContext = .previewContext) -> Result<String, NamingError> {
        Result { try relativeDestination(for: file, context: context) }
            .mapError { ($0 as? NamingError) ?? .unknownToken("") }
    }

    /// Validação estática de um template: tokens e modificadores conhecidos
    /// (ou campos de sessão declarados). Para usar ao salvar/carregar preset.
    public static func validateTokensExist(in template: String, knownSessionKeys: Set<String>) throws {
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                let inner = String(template[template.index(after: i)..<close])
                let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let name = parts[0]
                if !knownTokens.contains(name) && !knownSessionKeys.contains(name) {
                    throw NamingError.unknownToken(name)
                }
                for mod in parts.dropFirst() where !knownModifiers.contains(mod) {
                    throw NamingError.unknownModifier(mod)
                }
                i = template.index(after: close)
            } else {
                i = template.index(after: i)
            }
        }
    }
}

public extension MediaFile {
    /// Arquivo de exemplo (foto Sony, data fixa) pra prévia ao vivo do editor de preset.
    static let previewSample = MediaFile(
        sourceURL: URL(fileURLWithPath: "/CARTAO/DCIM/100MSDCF/DSC00001.JPG"),
        relPath: "DCIM/100MSDCF/DSC00001.JPG",
        size: 24_000_000, type: .photo,
        captureDate: Date(timeIntervalSince1970: 1_780_000_000)  // 2026-05-28 17:26:40 -03
    )
}

public extension NamingContext {
    /// Contexto de exemplo casado com `MediaFile.previewSample`.
    static let previewContext = NamingContext(camera: "A7IV", counter: 1, cardName: "SONY")
}
