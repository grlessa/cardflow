import Foundation
import OffloadKit

/// Estado e lógica do editor de preset (Plano 6). Separado da `PresetEditorView`
/// pra manter a view declarativa: aqui ficam o draft, a prévia ao vivo e as edições.
@MainActor @Observable
final class PresetEditorModel: Identifiable {

    enum Step: Int, CaseIterable, Identifiable {
        case basico, nomeacao, avancado
        public var id: Int { rawValue }
        var titulo: String {
            switch self {
            case .basico: return "Básico"
            case .nomeacao: return "Nomeação"
            case .avancado: return "Avançado"
            }
        }
    }
    var step: Step = .basico

    // Fonte da verdade do construtor de peças. Ao mudar, serializa de volta pro draft.
    var folderSegments: [TemplateSegment] = [] { didSet { draft.folderStructure = TemplateTokenizer.serialize(folderSegments) } }
    var nameSegments: [TemplateSegment] = [] { didSet { draft.rename.template = TemplateTokenizer.serialize(nameSegments) } }

    nonisolated let id = UUID()   // identidade da apresentação (.sheet(item:))
    var draft: Preset
    let isNew: Bool        // ainda não tem .cfp salvo
    let canDelete: Bool    // editando um preset salvo (≠ fábrica)

    private init(draft: Preset, isNew: Bool, canDelete: Bool) {
        self.draft = draft; self.isNew = isNew; self.canDelete = canDelete
        self.folderSegments = TemplateTokenizer.parse(draft.folderStructure)
        self.nameSegments = TemplateTokenizer.parse(draft.rename.template)
    }

    /// "Novo": começa do preset de fábrica com id fresco e nome em branco.
    static func creating() -> PresetEditorModel {
        var p = Preset.factoryDefault
        p.id = UUID().uuidString
        p.name = ""
        return .init(draft: p, isNew: true, canDelete: false)
    }

    /// "Editar": presets salvos editam no lugar; o de fábrica vira uma cópia nova
    /// (a fábrica é especial e nunca é sobrescrita).
    static func editing(_ preset: Preset) -> PresetEditorModel {
        if preset.id == Preset.factoryDefault.id {
            var p = preset
            p.id = UUID().uuidString
            p.name = preset.name + " (cópia)"
            return .init(draft: p, isNew: true, canDelete: false)
        }
        return .init(draft: preset, isNew: false, canDelete: true)
    }

    // MARK: - Operações de edição de segmentos

    enum Row { case folder, name }

    private func segments(_ row: Row) -> [TemplateSegment] { row == .folder ? folderSegments : nameSegments }
    private func setSegments(_ row: Row, _ segs: [TemplateSegment]) {
        if row == .folder { folderSegments = segs } else { nameSegments = segs }
    }

    /// Adiciona um token no fim, inserindo o separador padrão antes se já houver conteúdo.
    func addToken(_ name: String, to row: Row) {
        var segs = segments(row)
        if !segs.isEmpty { segs.append(.literal(row == .folder ? "/" : "_")) }
        segs.append(.token(name: name, modifiers: []))
        setSegments(row, segs)
    }

    func removeSegment(at index: Int, in row: Row) {
        var segs = segments(row)
        guard segs.indices.contains(index) else { return }
        segs.remove(at: index)
        setSegments(row, TemplateTokenizer.tidySeparators(segs))
    }

    func moveSegment(from: Int, to: Int, in row: Row) {
        var segs = segments(row)
        guard from != to, segs.indices.contains(from) else { return }
        let item = segs.remove(at: from)
        let dest = from < to ? to - 1 : to        // ajusta o deslocamento após o remove
        segs.insert(item, at: max(0, min(dest, segs.count)))
        setSegments(row, TemplateTokenizer.tidySeparators(segs))
    }

    /// Troca os modificadores de um token (caixa). nil = sem modificador de caixa.
    func setCaseModifier(_ mod: String?, at index: Int, in row: Row) {
        var segs = segments(row)
        guard segs.indices.contains(index), case .token(let n, _) = segs[index] else { return }
        segs[index] = .token(name: n, modifiers: mod.map { [$0] } ?? [])
        setSegments(row, segs)
    }

    func setSeparator(_ text: String, at index: Int, in row: Row) {
        var segs = segments(row)
        guard segs.indices.contains(index), case .literal = segs[index] else { return }
        segs[index] = .literal(text)
        setSegments(row, segs)
    }

    static let dateFormatPresets: [(label: String, format: String)] = [
        ("2026-05-28", "yyyy-MM-dd"),
        ("28-05-2026", "dd-MM-yyyy"),
        ("20260528", "yyyyMMdd"),
        ("2026-05-28_172640", "yyyy-MM-dd_HHmmss"),
    ]
    func setDateFormat(_ format: String) { draft.dateFormat = format }

    // MARK: - Campos de sessão

    func addSessionField() {
        var n = draft.sessionFields.count + 1
        while draft.sessionFields.contains(where: { $0.key == "campo\(n)" }) { n += 1 }
        draft.sessionFields.append(.init(key: "campo\(n)", label: "Campo \(n)"))
    }

    func removeSessionField(at index: Int) {
        guard draft.sessionFields.indices.contains(index) else { return }
        let key = draft.sessionFields[index].key
        draft.sessionFields.remove(at: index)
        // tira as pills que apontavam pra essa chave (senão viram token desconhecido e travam o preset)
        func dropOrphans(_ segs: [TemplateSegment]) -> [TemplateSegment] {
            TemplateTokenizer.tidySeparators(segs.filter {
                if case .token(let n, _) = $0 { return n != key }
                return true
            })
        }
        folderSegments = dropOrphans(folderSegments)
        nameSegments = dropOrphans(nameSegments)
    }

    /// Erro nos campos personalizados: chave vazia, repetida ou colidindo com token do sistema.
    var sessionFieldsError: String? {
        var seen = Set<String>()
        for f in draft.sessionFields {
            let k = f.key.trimmingCharacters(in: .whitespaces)
            if k.isEmpty { return "Todo campo personalizado precisa de uma chave." }
            if NameBuilder.knownTokens.contains(k) { return "A chave \u{201C}\(k)\u{201D} já é um token do sistema — escolha outra." }
            if !seen.insert(k).inserted { return "Chave de campo repetida: \u{201C}\(k)\u{201D}." }
        }
        return nil
    }

    // MARK: - Prévia ao vivo

    private var previewResult: Result<String, NamingError> {
        // usa as chaves já normalizadas (trimadas), como save() e templateError fazem,
        // pra prévia e validação não discordarem por causa de espaço nas bordas da chave.
        var p = draft
        p.sessionFields = p.sessionFields.map {
            .init(key: $0.key.trimmingCharacters(in: .whitespaces), label: $0.label)
        }
        return NameBuilder(preset: p).preview()
    }

    /// Pasta/nome renderizados pelo motor real, ou "" se o template estiver inválido.
    var previewText: String {
        if case .success(let s) = previewResult { return s }
        return ""
    }

    /// Mensagem amigável quando o template tem token/modificador inválido.
    var previewError: String? { Self.message(for: previewResult) }

    private static func message(for result: Result<String, NamingError>) -> String? {
        guard case .failure(let e) = result else { return nil }
        switch e {
        case .unknownToken(let t): return "Token desconhecido: {\(t)}"
        case .unknownModifier(let m): return "Modificador desconhecido: :\(m)"
        case .pathTraversal: return "A estrutura não pode sair da pasta de destino (sem “..”, “/” ou “~” no início)."
        }
    }

    /// Erro de template considerando AMBOS os campos (estrutura + nome), mesmo com renome desligado —
    /// espelha o que `PresetStore.validate` vai cobrar ao salvar.
    var templateError: String? {
        let keys = Set(draft.sessionFields.map { $0.key.trimmingCharacters(in: .whitespaces) })
        var templates = [draft.folderStructure]
        if draft.rename.enabled { templates.append(draft.rename.template) }   // nome só conta se renomeia
        for tmpl in templates {
            do { try NameBuilder.validateTokensExist(in: tmpl, knownSessionKeys: keys) }
            catch let e as NamingError { return Self.message(for: .failure(e)) }
            catch {}
        }
        return nil
    }

    // MARK: - Salvar

    var trimmedName: String { draft.name.trimmingCharacters(in: .whitespaces) }

    /// Por que o botão Salvar está desabilitado (nil = pode salvar). Mostrado na UI.
    var saveDisabledReason: String? {
        if trimmedName.isEmpty { return "Dê um nome ao preset." }
        if let e = sessionFieldsError { return e }
        if let e = templateError { return e }
        return nil
    }
    var canSave: Bool { saveDisabledReason == nil }

    /// Grava o preset (`<id>.cfp`). As extensões já estão no draft (editadas por chips). `false` se falhar.
    @discardableResult
    func save(into store: PresetStore) -> Bool {
        var p = draft
        p.name = trimmedName
        p.sessionFields = p.sessionFields.map {
            .init(key: $0.key.trimmingCharacters(in: .whitespaces),
                  label: $0.label.trimmingCharacters(in: .whitespaces))
        }
        do { try store.save(p); return true } catch { return false }
    }
}
