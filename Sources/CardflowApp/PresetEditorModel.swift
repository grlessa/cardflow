import Foundation
import OffloadKit

/// Estado e lógica do editor de preset (Plano 6). Separado da `PresetEditorView`
/// pra manter a view declarativa: aqui ficam o draft, a prévia ao vivo e as edições.
@MainActor @Observable
final class PresetEditorModel: Identifiable {

    enum Step: Int, CaseIterable, Identifiable {
        case basico, nomeacao
        public var id: Int { rawValue }
        var titulo: String {
            switch self {
            case .basico: return String(localized: "preset.step.basic")
            case .nomeacao: return String(localized: "preset.step.naming")
            }
        }
    }
    var step: Step = .basico

    // Fonte da verdade do construtor de peças. Ao mudar, serializa de volta pro draft.
    // Pastas: uma lista de NÍVEIS (cada nível = uma pasta/linha); junta com "/" só na serialização.
    var folderLevels: [[TemplateSegment]] = [] { didSet { draft.folderStructure = TemplateTokenizer.joinLevels(folderLevels) } }
    var nameSegments: [TemplateSegment] = [] { didSet { draft.rename.template = TemplateTokenizer.serialize(nameSegments) } }

    nonisolated let id = UUID()   // identidade da apresentação (.sheet(item:))
    var draft: Preset
    let original: Preset   // snapshot pra detectar edição não salva (#23)
    let isNew: Bool        // ainda não tem .cfp salvo
    let canDelete: Bool    // editando um preset salvo (≠ fábrica)
    var otherNames: Set<String> = []   // nomes dos OUTROS presets (pra avisar nome duplicado, #23)

    private init(draft: Preset, isNew: Bool, canDelete: Bool) {
        self.draft = draft; self.original = draft; self.isNew = isNew; self.canDelete = canDelete
        self.folderLevels = TemplateTokenizer.levels(from: draft.folderStructure)
        self.nameSegments = TemplateTokenizer.parse(draft.rename.template)
    }

    /// Tem edição ainda não salva? (pra confirmar antes de descartar)
    var hasUnsavedChanges: Bool { draft != original }
    /// Nome igual ao de outro preset → aviso não-bloqueante (dois indistinguíveis no Picker).
    var duplicateNameWarning: String? {
        otherNames.contains(trimmedName) ? String(localized: "preset.warning.duplicateName") : nil
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
            p.name = String(localized: "preset.copyNameSuffix \(preset.name)")
            return .init(draft: p, isNew: true, canDelete: false)
        }
        return .init(draft: preset, isNew: false, canDelete: true)
    }

    // MARK: - Operações de edição de segmentos

    /// Uma "lane" de peças: o nome do arquivo, ou um NÍVEL de pasta (uma linha do construtor).
    enum Lane: Equatable, Hashable { case name; case folder(Int) }

    private func segs(_ lane: Lane) -> [TemplateSegment] {
        switch lane {
        case .name: return nameSegments
        case .folder(let i): return folderLevels.indices.contains(i) ? folderLevels[i] : []
        }
    }
    private func setSegs(_ lane: Lane, _ v: [TemplateSegment]) {
        switch lane {
        case .name: nameSegments = v
        case .folder(let i): if folderLevels.indices.contains(i) { folderLevels[i] = v }
        }
    }
    /// Separador padrão DENTRO de uma lane: espaço numa pasta, "_" num nome de arquivo.
    private func defaultJoiner(_ lane: Lane) -> String { if case .folder = lane { return " " }; return "_" }

    /// Adiciona um token no fim da lane (com o separador padrão antes, se já houver peças).
    func addToken(_ name: String, to lane: Lane) {
        var s = segs(lane)
        if !s.isEmpty { s.append(.literal(defaultJoiner(lane))) }
        s.append(.token(name: name, modifiers: []))
        setSegs(lane, s)
    }

    /// Adiciona uma peça de TEXTO LIVRE editável (ex.: "Culto") no fim da lane.
    func addText(to lane: Lane) {
        var s = segs(lane)
        if !s.isEmpty { s.append(.literal(defaultJoiner(lane))) }
        s.append(.literal("texto"))
        setSegs(lane, s)
    }

    func removeSegment(at index: Int, in lane: Lane) {
        var s = segs(lane)
        guard s.indices.contains(index) else { return }
        s.remove(at: index)
        setSegs(lane, TemplateTokenizer.tidySeparators(s))
    }

    func moveSegment(from: Int, to: Int, in lane: Lane) {
        var s = segs(lane)
        guard from != to, s.indices.contains(from) else { return }
        let item = s.remove(at: from)
        let dest = from < to ? to - 1 : to        // ajusta o deslocamento após o remove
        s.insert(item, at: max(0, min(dest, s.count)))
        setSegs(lane, TemplateTokenizer.tidySeparators(s))
    }

    /// Troca os modificadores de um token (caixa). nil = sem modificador de caixa.
    func setCaseModifier(_ mod: String?, at index: Int, in lane: Lane) {
        var s = segs(lane)
        guard s.indices.contains(index), case .token(let n, _) = s[index] else { return }
        s[index] = .token(name: n, modifiers: mod.map { [$0] } ?? [])
        setSegs(lane, s)
    }

    func setSeparator(_ text: String, at index: Int, in lane: Lane) {
        var s = segs(lane)
        guard s.indices.contains(index), case .literal = s[index] else { return }
        s[index] = .literal(text)
        setSegs(lane, s)
    }

    /// Edita o texto de uma peça de texto livre (tira "/" pra não criar pasta dentro de um nome/nível).
    func setText(_ text: String, at index: Int, in lane: Lane) {
        var s = segs(lane)
        guard s.indices.contains(index), case .literal = s[index] else { return }
        s[index] = .literal(text.replacingOccurrences(of: "/", with: ""))
        setSegs(lane, s)
    }

    // MARK: - Níveis de pasta (cada nível é uma pasta/linha)

    func addFolderLevel() { folderLevels.append([]) }
    func removeFolderLevel(_ index: Int) {
        guard folderLevels.indices.contains(index) else { return }
        folderLevels.remove(at: index)
    }

    static let dateFormatPresets: [(label: String, format: String)] = [
        ("2026-05-28", "yyyy-MM-dd"),
        ("28-05-2026", "dd-MM-yyyy"),
        ("28-05-26", "dd-MM-yy"),
        ("28-05", "dd-MM"),                 // sem ano
        ("28.05.2026", "dd.MM.yyyy"),       // separador "."
        ("20260528", "yyyyMMdd"),           // sem separador
        // prévias por extenso: o rótulo segue o idioma; o formato é técnico (NameBuilder).
        (String(localized: "pill.dateFormat.longFull"), "dd 'de' MMMM 'de' yyyy"),
        (String(localized: "pill.dateFormat.longNoYear"), "dd 'de' MMMM"),
        (String(localized: "pill.dateFormat.longMonthYear"), "MMMM 'de' yyyy"),
    ]
    func setDateFormat(_ format: String) { draft.dateFormat = format }

    static let timeFormatPresets: [(label: String, format: String)] = [
        ("172640", "HHmmss"),
        ("17h26", "HH'h'mm"),
        ("17h26m40s", "HH'h'mm'm'ss's'"),
        ("17-26-40", "HH-mm-ss"),
    ]
    func setTimeFormat(_ format: String) { draft.timeFormat = format }

    // MARK: - Campos de sessão

    func addSessionField() {
        var n = draft.sessionFields.count + 1
        while draft.sessionFields.contains(where: { $0.key == "campo\(n)" }) { n += 1 }
        draft.sessionFields.append(.init(key: "campo\(n)", label: String(localized: "preset.sessionField.defaultLabel \(n)")))
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
        folderLevels = folderLevels.map(dropOrphans)
        nameSegments = dropOrphans(nameSegments)
    }

    /// Erro nos campos personalizados: chave vazia, repetida ou colidindo com token do sistema.
    var sessionFieldsError: String? {
        var seen = Set<String>()
        for f in draft.sessionFields {
            let k = f.key.trimmingCharacters(in: .whitespaces)
            if k.isEmpty { return String(localized: "preset.validation.sessionFieldKeyEmpty") }
            if NameBuilder.knownTokens.contains(k) { return String(localized: "preset.validation.sessionFieldKeyReserved \(k)") }
            if !seen.insert(k).inserted { return String(localized: "preset.validation.sessionFieldKeyDuplicate \(k)") }
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
        return NameBuilder(preset: p, locale: AppLocale.effective).preview()
    }

    /// Pasta/nome renderizados pelo motor real, ou "" se o template estiver inválido.
    var previewText: String {
        if case .success(let s) = previewResult { return s }
        return ""
    }

    /// Mensagem amigável quando o template tem token/modificador inválido.
    var previewError: String? { Self.message(for: previewResult) }

    /// Prévia estruturada: as PASTAS (na ordem) e o NOME do arquivo, pra mostrar como caminho visual.
    var previewParts: (folders: [String], file: String)? {
        guard case .success(let s) = previewResult else { return nil }
        var comps = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let file = comps.popLast() else { return nil }
        return (comps, file)
    }

    private static func message(for result: Result<String, NamingError>) -> String? {
        guard case .failure(let e) = result else { return nil }
        switch e {
        case .unknownToken(let t): return String(localized: "preset.error.unknownToken \(t)")
        case .unknownModifier(let m): return String(localized: "preset.error.unknownModifier \(m)")
        case .pathTraversal: return String(localized: "preset.error.pathTraversal")
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
    /// Mensagem de erro quando o salvamento em disco falha — pra a sheet NÃO fechar engolindo a edição.
    var saveError: String?

    /// Por que o botão Salvar está desabilitado (nil = pode salvar). Mostrado na UI.
    var saveDisabledReason: String? {
        if trimmedName.isEmpty { return String(localized: "preset.validation.nameRequired") }
        // #9: estrutura de pastas vazia passa em validateTokensExist (nada pra validar) mas o
        // PresetStore.validate rejeita ao salvar — então a sheet fecharia descartando tudo em silêncio.
        // Pega aqui pra o botão já avisar antes.
        if draft.folderStructure.split(separator: "/", omittingEmptySubsequences: true).isEmpty {
            return String(localized: "preset.validation.folderRequired")
        }
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
