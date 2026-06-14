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
    public var lote: Int?          // número do lote (descarga), quando a estrutura usa {lote}
    public init(camera: String, counter: Int, cardName: String = "", sessionValues: [String: String] = [:], lote: Int? = nil) {
        self.camera = camera; self.counter = counter; self.cardName = cardName
        self.sessionValues = sessionValues; self.lote = lote
    }
}

public struct NameBuilder {
    private let preset: Preset
    let timeZone: TimeZone
    private let locale: Locale

    /// `locale` controla o idioma de mês/dia ({mes_nome}, {mes_abrev}, {data}). Sem injeção, cai no pt-BR base.
    public init(preset: Preset, timeZone: TimeZone = .current, locale: Locale? = nil) {
        self.preset = preset; self.timeZone = timeZone
        self.locale = locale ?? Locale(identifier: "pt-BR")
    }

    public static let knownTokens: Set<String> = [
        "evento", "tipo", "camera", "cartao", "lote", "nome_original", "ext", "pasta_origem", "contador",
        "ano", "ano2", "mes", "mes_abrev", "mes_nome", "dia", "dia_semana", "dia_semana_abrev",
        "horas", "minutos", "segundos", "data", "hora", "turno",
    ]
    public static let knownModifiers: Set<String> = ["maiuscula", "minuscula"]

    /// Ordem de exibição dos tokens no picker do editor (mais comuns primeiro).
    /// `Set(tokenOrder) == knownTokens` é garantido por teste — não deixar um token de fora.
    public static let tokenOrder: [String] = [
        "evento", "tipo", "camera", "cartao", "lote",
        "nome_original", "ext", "contador", "pasta_origem",
        "ano", "ano2", "mes", "mes_abrev", "mes_nome", "dia", "dia_semana", "dia_semana_abrev",
        "horas", "minutos", "segundos", "data", "hora", "turno",
    ]

    // valor NATURAL (caixa normal) — pra o toggle Aa/AB/ab funcionar: Aa="Foto", AB="FOTO", ab="foto".
    // Sem acento de propósito: vira nome de pasta, e nome de pasta tem que ser seguro.
    private func tipoFolder(for type: FileType) -> String {
        let lang = locale.language.languageCode?.identifier ?? "pt"
        switch (type, lang) {
        case (.photo, "en"): return "Photo"
        case (.photo, _):    return "Foto"
        case (.video, _):    return "Video"
        case (.audio, _):    return "Audio"
        case (_, "en"):      return "Other"
        case (_, "es"):      return "Otros"
        default:             return "Outros"
        }
    }

    // Dia da semana por idioma (tabelas fixas → "Segunda"/"Seg" limpos, sem "-feira" nem ponto que o
    // DateFormatter traria em pt). Fuso do builder. Calendar.weekday: 1=Domingo … 7=Sábado.
    private func diaSemana(for date: Date, abbreviated: Bool) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let i = cal.component(.weekday, from: date) - 1   // 0=Domingo
        let lang = locale.language.languageCode?.identifier ?? "pt"
        let full: [String], abbr: [String]
        switch lang {
        case "en":
            full = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            abbr = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        case "es":
            full = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"]
            abbr = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"]
        default:
            full = ["Domingo", "Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado"]
            abbr = ["Dom", "Seg", "Ter", "Qua", "Qui", "Sex", "Sáb"]
        }
        return (abbreviated ? abbr : full)[i]
    }

    // Rótulo do lote (descarga) por idioma — vira nome de pasta, então tabela fixa por Locale
    // igual a turnoFolder/tipoFolder. Compartilhado: o CopyService reusa pros bundles de cinema.
    // pt "Lote", en "Batch", es "Lote".
    public static func loteLabel(for locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier ?? "pt"
        return lang == "en" ? "Batch" : "Lote"
    }

    // Turno pela hora LOCAL de captura (fuso do builder). Noite engole a madrugada (18h–6h).
    // Strings por idioma — mesmo critério de faixa horária em todos.
    private func turnoFolder(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let lang = locale.language.languageCode?.identifier ?? "pt"
        let h = cal.component(.hour, from: date)
        let idx = (6..<12).contains(h) ? 0 : (12..<18).contains(h) ? 1 : 2   // manhã / tarde / noite
        switch lang {
        case "en": return ["Morning", "Afternoon", "Night"][idx]
        case "es": return ["Mañana", "Tarde", "Noche"][idx]
        default:   return ["Manhã", "Tarde", "Noite"][idx]
        }
    }

    private func df(_ format: String, _ date: Date, locale: Locale = Locale(identifier: "en_US_POSIX")) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = format
        return f.string(from: date)
    }

    private func month(_ date: Date, abbreviated: Bool) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let m = cal.component(.month, from: date) - 1   // 0-based
        let f = DateFormatter(); f.locale = locale
        let symbols = abbreviated ? f.shortStandaloneMonthSymbols : f.standaloneMonthSymbols
        guard let raw0 = symbols?[safe: m] else { return "" }
        let raw = raw0.replacingOccurrences(of: ".", with: "")
        return raw.isEmpty ? raw : raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private func baseValue(_ name: String, file: MediaFile, ctx: NamingContext) -> String? {
        let last = (file.relPath as NSString).lastPathComponent
        switch name {
        case "evento": return preset.evento
        case "tipo": return tipoFolder(for: file.type)
        case "camera": return ctx.camera
        case "cartao": return ctx.cardName
        case "lote": return Self.loteLabel(for: locale) + " " + String(format: "%02d", ctx.lote ?? 1)
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
        case "dia_semana": return diaSemana(for: file.captureDate, abbreviated: false)
        case "dia_semana_abrev": return diaSemana(for: file.captureDate, abbreviated: true)
        case "horas": return df("HH", file.captureDate)
        case "minutos": return df("mm", file.captureDate)
        case "segundos": return df("ss", file.captureDate)
        case "data": return df(preset.dateFormat, file.captureDate, locale: locale)   // mês segue o idioma do builder
        case "hora": return df(preset.timeFormat, file.captureDate)
        case "turno": return turnoFolder(for: file.captureDate)
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
        var cleaned = s
        for ch in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"] {
            cleaned = cleaned.replacingOccurrences(of: ch, with: "-")
        }
        // remove caracteres de controle (TAB, newline, \r, NUL e cia.): criam arquivos que parecem
        // corrompidos, difíceis de selecionar no Finder, e quebram scripts. NUL é categoria de controle.
        cleaned.unicodeScalars.removeAll { $0.properties.generalCategory == .control }
        // normaliza pra NFC (forma canônica): cartões diferentes gravam acentos em NFC ou NFD;
        // sem isto o mesmo "Café" sairia inconsistente entre fontes.
        cleaned = cleaned.precomposedStringWithCanonicalMapping
        if cleaned == "." { return "_" }
        if cleaned == ".." { return "__" }
        return cleaned
    }

    /// Trunca um componente de path pra caber no limite de bytes do filesystem (APFS ≈ 255 bytes/componente).
    /// Acentos pt-BR custam 2-3 bytes cada em UTF-8, então um nome de evento entusiasmado estoura fácil.
    /// Corta em fronteira de caractere (nunca no meio de um grapheme) e preserva a extensão do arquivo.
    static func truncateComponent(_ s: String, maxBytes: Int, keepingExtension: Bool) -> String {
        guard s.utf8.count > maxBytes else { return s }
        if keepingExtension {
            let ns = s as NSString
            let ext = ns.pathExtension
            let stem = ns.deletingPathExtension
            let extBudget = ext.isEmpty ? 0 : ext.utf8.count + 1   // ".ext"
            let cut = truncateToBytes(stem, maxBytes: max(1, maxBytes - extBudget))
            return ext.isEmpty ? cut : "\(cut).\(ext)"
        }
        return truncateToBytes(s, maxBytes: maxBytes)
    }

    private static func truncateToBytes(_ s: String, maxBytes: Int) -> String {
        var out = ""
        var bytes = 0
        for ch in s {
            let c = String(ch).utf8.count
            if bytes + c > maxBytes { break }
            out.append(ch); bytes += c
        }
        return out
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
        let originalName = (file.relPath as NSString).lastPathComponent
        var fileName: String
        if preset.rename.enabled {
            let rendered = try render(preset.rename.template, file: file, ctx: ctx)
            let ext = (file.relPath as NSString).pathExtension
            // #7: se o template renderiza vazio (evento vazio, campo de sessão em branco, só
            // separadores), cai pro nome ORIGINAL — senão viraria ".JPG" (oculto no Finder) ou
            // ".JPG_<hash>" (oculto E sem extensão válida). Footage oculto, pro leigo, é footage perdido.
            let originalStem = (originalName as NSString).deletingPathExtension
            let stem = Self.isEffectivelyEmpty(rendered) ? originalStem : rendered
            if stem.isEmpty {
                fileName = originalName
            } else {
                fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
            }
        } else {
            fileName = originalName
        }
        // #8: nenhum componente pode passar do limite do filesystem, senão o FileManager lança
        // ENAMETOOLONG e derruba o offload INTEIRO. Trunca cada segmento de pasta e o nome do arquivo.
        let safeFolder = folder.split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.truncateComponent(String($0), maxBytes: 200, keepingExtension: false) }
            .joined(separator: "/")
        let safeFile = Self.truncateComponent(fileName, maxBytes: 200, keepingExtension: true)
        return safeFolder + "/" + safeFile
    }

    /// "Vazio na prática": só separadores/espaços (ou nada). Um stem assim viraria arquivo oculto.
    private static func isEffectivelyEmpty(_ s: String) -> Bool {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " -_.").union(.whitespacesAndNewlines)).isEmpty
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

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
