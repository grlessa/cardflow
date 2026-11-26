import Foundation
import OffloadKit

/// Estado e lógica do editor de modelo de pastas no painel inspetor.
@MainActor @Observable
final class PresetEditorModel {
    // Fonte da verdade do construtor de peças. Ao mudar, serializa de volta pro draft.
    // Pastas: uma lista de NÍVEIS (cada nível = uma pasta/linha); junta com "/" só na serialização.
    var folderLevels: [[TemplateSegment]] = [] { didSet { draft.folderStructure = TemplateTokenizer.joinLevels(folderLevels) } }
    /// IDs estáveis por nível de pasta (mantém o popover preso ao nível certo ao mover pra cima/baixo).
    var folderLevelIDs: [UUID] = []
    var nameSegments: [TemplateSegment] = [] { didSet { draft.rename.template = TemplateTokenizer.serialize(nameSegments) } }

    var draft: Preset
    private(set) var original: Preset   // snapshot do último estado salvo (detecta edição não salva)
    let isNew: Bool                     // ainda não tem .cfp salvo (modelo de fábrica em rascunho)
    let canDelete: Bool                 // editando um modelo salvo (≠ fábrica)
    var otherNames: Set<String> = []    // nomes dos OUTROS modelos (pra avisar nome duplicado)

    private init(draft: Preset, original: Preset, isNew: Bool, canDelete: Bool) {
        self.draft = draft; self.original = original; self.isNew = isNew; self.canDelete = canDelete
        let levels = TemplateTokenizer.levels(from: draft.folderStructure)
        self.folderLevels = levels
        self.folderLevelIDs = levels.map { _ in UUID() }
        self.nameSegments = TemplateTokenizer.parse(draft.rename.template)
    }

    /// Tem edição ainda não salva?
    var hasUnsavedChanges: Bool { draft != original }

    /// Atualiza o snapshot após um autosave bem-sucedido (permite salvar reversões posteriores).
    func markSaved(_ saved: Preset) { original = saved }

    /// Nome igual ao de outro modelo -> aviso não-bloqueante (dois indistinguíveis no seletor).
    var duplicateNameWarning: String? {
        otherNames.contains(trimmedName) ? String(localized: "preset.warning.duplicateName") : nil
    }

    /// Nome do arquivo sem peça única por arquivo ({contador} ou {nome_original}): dois arquivos geram o
    /// mesmo nome e o motor desempata acrescentando data e hora (_2026-06-22_172640), o que surpreende.
    var nameMayRepeat: Bool {
        draft.rename.enabled && !nameSegments.contains {
            if case .token(let name, _) = $0 { return name == "contador" || name == "nome_original" }
            return false
        }
    }

    /// "Editar": modelos salvos editam no lugar; o de fábrica vira um rascunho de modelo novo
    /// (a fábrica é especial e nunca é sobrescrita). Se `restoringDraft` for fornecido, retoma um
    /// rascunho ainda não salvo mantendo `original` no ponto de partida.
    static func editing(_ preset: Preset, restoringDraft: Preset? = nil) -> PresetEditorModel {
        if preset.id == Preset.factoryDefault.id {
            var base = preset
            base.id = restoringDraft?.id ?? UUID().uuidString
            base.name = String(localized: "preset.copyNameSuffix \(preset.name)")
            let current = restoringDraft ?? base
            return .init(draft: current, original: base, isNew: true, canDelete: false)
        }
        return .init(draft: restoringDraft ?? preset, original: preset, isNew: false, canDelete: true)
    }

    // MARK: - Níveis de pasta (cada nível é uma pasta/linha)

    func addFolderLevel() {
        folderLevelIDs.append(UUID())
        folderLevels.append([])
    }
    func removeFolderLevel(_ index: Int) {
        guard folderLevels.indices.contains(index) else { return }
        folderLevels.remove(at: index)
        if folderLevelIDs.indices.contains(index) { folderLevelIDs.remove(at: index) }
    }
    func moveFolderLevel(from index: Int, to destination: Int) {
        guard folderLevels.indices.contains(index), folderLevels.indices.contains(destination) else { return }
        folderLevels.swapAt(index, destination)
        if folderLevelIDs.indices.contains(index), folderLevelIDs.indices.contains(destination) {
            folderLevelIDs.swapAt(index, destination)
        }
    }

    // MARK: - Campos de sessão

    func addSessionField() {
        var n = draft.sessionFields.count + 1
        while draft.sessionFields.contains(where: { $0.key == "campo\(n)" }) { n += 1 }
        draft.sessionFields.append(.init(key: "campo\(n)", label: String(localized: "preset.sessionField.defaultLabel \(n)")))
    }

    func removeSessionField(key: String) {
        guard let index = draft.sessionFields.firstIndex(where: { $0.key == key }) else { return }
        removeSessionField(at: index)
    }

    func removeSessionField(at index: Int) {
        guard draft.sessionFields.indices.contains(index) else { return }
        let key = draft.sessionFields[index].key
        draft.sessionFields.remove(at: index)
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
        var p = draft
        p.sessionFields = p.sessionFields.map {
            .init(key: $0.key.trimmingCharacters(in: .whitespaces), label: $0.label)
        }
        return NameBuilder(preset: p, locale: AppLocale.effective).preview()
    }

    /// Mensagem amigável quando o template tem token/modificador inválido.
    var previewError: String? { Self.message(for: previewResult) }

    private static func message(for result: Result<String, NamingError>) -> String? {
        guard case .failure(let e) = result else { return nil }
        return AppModel.localizedMessage(for: e)
    }

    /// Erro de template considerando estrutura e nome (quando renomear está ligado).
    var templateError: String? {
        let keys = Set(draft.sessionFields.map { $0.key.trimmingCharacters(in: .whitespaces) })
        var templates = [draft.folderStructure]
        if draft.rename.enabled {
            if draft.rename.template.contains("/") {
                return AppModel.localizedMessage(for: NamingError.pathTraversal(draft.rename.template))
            }
            templates.append(draft.rename.template)
        }
        for tmpl in templates {
            do {
                try NameBuilder.validateNoTraversal(in: tmpl)
                try NameBuilder.validateTokensExist(in: tmpl, knownSessionKeys: keys)
            } catch let e as NamingError { return Self.message(for: .failure(e)) }
            catch {}
        }
        return nil
    }

    // MARK: - Salvar

    var trimmedName: String { draft.name.trimmingCharacters(in: .whitespaces) }

    /// Por que o botão Salvar está desabilitado (nil = pode salvar). Mostrado na UI.
    var saveDisabledReason: String? {
        if trimmedName.isEmpty { return String(localized: "preset.validation.nameRequired") }
        if draft.folderStructure.split(separator: "/", omittingEmptySubsequences: true).isEmpty {
            return String(localized: "preset.validation.folderRequired")
        }
        if let e = sessionFieldsError { return e }
        if let e = templateError { return e }
        return nil
    }
    var canSave: Bool { saveDisabledReason == nil }

    /// Monta o preset normalizado pronto para gravar em disco.
    func normalizedForSave() -> Preset {
        var p = draft
        p.name = trimmedName
        p.sessionFields = p.sessionFields.map {
            .init(key: $0.key.trimmingCharacters(in: .whitespaces),
                  label: $0.label.trimmingCharacters(in: .whitespaces))
        }
        return p
    }

    /// Grava o preset (`<id>.cfp`). `false` se falhar.
    @discardableResult
    func save(into store: PresetStore) -> Bool {
        let p = normalizedForSave()
        do {
            try store.save(p)
            markSaved(p)
            return true
        } catch {
            return false
        }
    }
}
