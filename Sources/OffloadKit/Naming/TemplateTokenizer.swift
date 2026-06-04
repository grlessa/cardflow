/// Converte uma string de template (ex.: "{evento}_{contador}") em segmentos editáveis e de volta.
/// É a camada que o construtor de peças (UI) usa sem expor a sintaxe "{}".
public enum TemplateTokenizer {
    public static func parse(_ template: String) -> [TemplateSegment] {
        var segments: [TemplateSegment] = []
        var literal = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{", let close = template[i...].firstIndex(of: "}") {
                if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
                let inner = String(template[template.index(after: i)..<close])
                let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                segments.append(.token(name: parts[0], modifiers: Array(parts.dropFirst())))
                i = template.index(after: close)
            } else {
                literal.append(template[i])
                i = template.index(after: i)
            }
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }

    public static func serialize(_ segments: [TemplateSegment]) -> String {
        segments.map { seg in
            switch seg {
            case .literal(let s): return s
            case .token(let name, let mods): return "{" + ([name] + mods).joined(separator: ":") + "}"
            }
        }.joined()
    }

    /// Literais que são separador puro (auto-inseridos entre peças). Texto livre NÃO entra aqui.
    public static let separators: Set<String> = ["/", "_", "-", " "]

    private static func isSeparator(_ seg: TemplateSegment) -> Bool {
        if case .literal(let s) = seg { return separators.contains(s) }
        return false
    }

    /// Limpa separadores soltos: tira no começo/fim e colapsa duplicados consecutivos —
    /// PRESERVANDO literais de texto livre (ex.: "_final", "v2") pra não apagar conteúdo do usuário.
    public static func tidySeparators(_ segs: [TemplateSegment]) -> [TemplateSegment] {
        var out: [TemplateSegment] = []
        for seg in segs {
            if isSeparator(seg), out.isEmpty { continue }                         // não começa com separador
            if isSeparator(seg), let last = out.last, isSeparator(last) { continue } // sem dois separadores juntos
            out.append(seg)
        }
        if let last = out.last, isSeparator(last) { out.removeLast() }             // não termina com separador
        return out
    }
}
