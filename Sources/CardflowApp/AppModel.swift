import Foundation
import AppKit
import OffloadKit
import CardFormatKit
import CardFormatXPC

/// Item selecionado na barra lateral.
enum SidebarItem: Hashable {
    case card(String)          // CardSession.id (caminho do volume)
    case destination(URL)
    case recent(String)        // offloadId
}

/// Estado do PROJETO (modelo, destinos, nome, campos) e a coleção de cartões conectados. O estado de
/// cada cartão mora no seu `CardSession`; a cópia, a formatação e a leitura ficam nas extensões
/// `AppModel+Cards`, `AppModel+Offload` e `AppModel+Format`.
@MainActor @Observable
final class AppModel {
    enum OffloadState: Equatable {
        case idle
        case running(OffloadProgress)
        case finished(OffloadOutcome)
        case failed(String, cardUncertain: Bool)   // cardUncertain: falhou DURANTE a cópia → avisar p/ não formatar
    }
    enum FormatUIState: Equatable {
        case idle, checking, confirming(CardWipeReport), blocked([String])
        case formatting(FormatStep), done(FormatPlan), failed(FormatFailure, String?)
    }
    enum CaptureDateFilter: Equatable {
        case all
        case today(anchor: Date)
        case singleDay(Date)
        case range(start: Date, end: Date)
    }
    /// Tudo que uma cópia usa, congelado na hora de enfileirar (a fila pode demorar; mudar o projeto ou o
    /// modelo depois não mexe no que já foi pedido). A trava de formatar reaplica as mesmas escolhas.
    struct OffloadContext: Equatable {
        let cardURL: URL; let cardName: String; let wholeDiskBSD: String?; let volumeUUID: String?
        let preset: Preset; let choices: WipeChoices; let destinations: [URL]
        var camera: String = ""
        /// Cartão com várias câmeras: câmera de cada grupo de origem.
        var cameras: [String: String] = [:]
        var sessionValues: [String: String] = [:]
        var fastResume = true
        var formatWhenDone = false
        var internalDestinations: Set<URL> = []
    }

    let watcher = VolumeWatcher()
    /// Formatação do cartão (permissão + ajudante). Injetável pra teste.
    let formatter: CardFormatting
    let presetStore: PresetStore
    let sessionStore = SessionStore(fileURL: SessionStore.appSessionFile())
    let history = HistoryStore()

    /// `presetsDirectory`: pasta dos modelos (teste usa uma temporária, nunca a do app).
    init(formatter: CardFormatting? = nil, presetsDirectory: URL? = nil) {
        self.formatter = formatter ?? FormatController()   // padrão resolvido aqui: o init é do ator principal
        self.presetStore = PresetStore(directory: presetsDirectory ?? PresetStore.appPresetsDirectory())
    }

    // MARK: Cartões

    /// Um por fonte conectada, na ordem das fontes.
    var cards: [CardSession] = []
    var selection: SidebarItem?
    /// A pessoa escolheu algo na barra lateral. Até isso, a seleção acompanha o primeiro cartão (a
    /// detecção em segundo plano faz os cartões chegarem em ordem variável).
    @ObservationIgnored var selectionByUser = false
    /// Cartão da seleção. Sem seleção (ou seleção de cartão que sumiu), o primeiro cartão.
    var selectedCard: CardSession? {
        switch selection {
        case .card(let id)?: return cards.first { $0.id == id } ?? cards.first
        case nil: return cards.first
        default: return nil
        }
    }
    func card(id: String) -> CardSession? { cards.first { $0.id == id } }

    @ObservationIgnored var batchCount = 0   // cartões na leva atual da fila (aviso "fila terminou")
    @ObservationIgnored lazy var queue = CopyQueue { [unowned self] id in await self.runOffload(cardID: id) }

    // MARK: Projeto

    /// "Formatar ao terminar": por sessão, sempre desligado quando o app abre (decisão do dono).
    var autoFormatThisSession = false
    var presets: [Preset] = []
    var selectedPresetId: String = Preset.factoryDefault.id
    /// Nome do projeto (pasta principal). Vazio = o do modelo.
    var projectName: String = ""
    var sessionValues: [String: String] = [:]    // valores de campos personalizados do modelo
    /// Mídia escolhida por último: cartão novo começa com ela.
    var defaultMediaChoice: Preset.Media.Kind = .both
    var formattingAvailable: Bool { formatter.permission == .ready }
    /// Erro de importação/exportação de modelo, pra um alerta.
    var modelError: String?
    /// Guia rápido aberto (primeira abertura ou menu Ajuda).
    var showOnboarding = false
    /// Tela de gerenciar modelos aberta.
    var showManageModels = false
    /// Painel do modelo de pastas aberto. Fica no modelo (e não só em @AppStorage) pra o menu Visualizar
    /// mostrar "Mostrar"/"Esconder" certo.
    var inspectorShown: Bool = UserDefaults.standard.bool(forKey: "cardflow.inspectorShown") {
        didSet { UserDefaults.standard.set(inspectorShown, forKey: "cardflow.inspectorShown") }
    }

    var activePreset: Preset {
        presets.first { $0.id == selectedPresetId } ?? .factoryDefault
    }
    /// Rascunho do painel do modelo quando ele ainda não foi salvo (o modelo de fábrica não muda: as
    /// alterações viram um modelo novo só quando o usuário salva). A prévia já mostra o rascunho.
    var previewPresetOverride: Preset?
    /// O modelo que vale agora: o rascunho em edição, ou o ativo.
    var workingPreset: Preset { previewPresetOverride ?? activePreset }
    /// Pasta principal efetiva (o que o usuário digitou, ou a do modelo), saneada: "Culto 09/06" vira
    /// "Culto 09-06" pra não criar subpasta acidental, igual ao que o token {projeto} produz.
    var effectiveEvento: String {
        let e = projectName.trimmingCharacters(in: .whitespaces)
        return NameBuilder.sanitizePathComponent(e.isEmpty ? workingPreset.evento : e)
    }
    /// O modelo como a PRÉVIA e a CÓPIA o veem: o ativo com a pasta principal do projeto. A prévia
    /// procura o registro parcial na MESMA pasta onde a cópia grava (senão a retomada não é detectada).
    var previewPreset: Preset {
        var p = workingPreset
        p.evento = effectiveEvento
        return p
    }
    /// O modelo ativo usa {camera}? (o campo Câmera só aparece quando faz diferença)
    var usesCameraToken: Bool {
        let p = workingPreset
        if p.folderStructure.contains("{camera}") { return true }
        return p.rename.enabled && p.rename.template.contains("{camera}")
    }

    @ObservationIgnored var liveSaveTask: Task<Void, Never>?
    @ObservationIgnored var pendingProgrammaticPresetId: String?   // id setado por restore/editor; o onChange compara por VALOR

    // MARK: Destinos

    var destinationURL: URL?          // disco principal
    var backupURL: URL?               // disco de backup (opcional; copia conferida em paralelo)
    var preferredDestUUID: String?    // disco que o USUÁRIO escolheu (por UUID), sticky a desmonte transitório
    @ObservationIgnored var destWasAutoSelected = false
    var internalPermissionDenied = false   // macOS bloqueou acesso à pasta interna escolhida (Mesa/Documentos)
    var destinationFreeBytes: Int64?
    var destinationTotalBytes: Int64?
    var backupFreeBytes: Int64?
    var backupTotalBytes: Int64?
    var forcedSources: Set<String> = []        // discos que o usuário marcou como cartão
    var forcedDestinations: Set<String> = []   // discos que o usuário marcou como destino
    /// Cache da detecção por conteúdo (lê o disco): por volume montado, podado quando ele sai.
    @ObservationIgnored var detectedAsCard: [String: Bool] = [:]

    /// Detecção por conteúdo em segundo plano (padrão). Abrir a raiz de um volume pode esperar a permissão
    /// do macOS ("volume removível") e isso nunca pode travar a janela. Nos testes é síncrona.
    @ObservationIgnored var detectInBackground = !AppModel.runningTests
    @ObservationIgnored private var classifying: Set<String> = []
    static let runningTests: Bool = {
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("testing") || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()

    /// É cartão (fonte)? Overrides do usuário, senão o tipo físico (instantâneo) ou o conteúdo.
    func isSource(_ v: ExternalVolume) -> Bool {
        if forcedDestinations.contains(v.id) { return false }
        if forcedSources.contains(v.id) { return true }
        if let cached = detectedAsCard[v.id] { return cached }
        if v.traits?.isCameraMedia == true { detectedAsCard[v.id] = true; return true }
        guard detectInBackground else {
            let r = CardDetection.isCard(v)
            detectedAsCard[v.id] = r
            return r
        }
        classifyInBackground(v)
        return false
    }

    /// Ainda sem saber se é cartão ou disco: não entra em nenhuma lista até a leitura terminar.
    func isClassified(_ v: ExternalVolume) -> Bool {
        forcedSources.contains(v.id) || forcedDestinations.contains(v.id) || detectedAsCard[v.id] != nil
    }

    private func classifyInBackground(_ v: ExternalVolume) {
        guard classifying.insert(v.id).inserted else { return }
        Task.detached { [weak self] in
            let r = CardDetection.isCard(v)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.classifying.remove(v.id)
                guard self.watcher.volumes.contains(where: { $0.id == v.id }) else { return }
                self.detectedAsCard[v.id] = r
                self.reconcileVolumes()
            }
        }
    }

    var sources: [ExternalVolume] { watcher.volumes.filter { isSource($0) } }
    /// Destinos do MAIOR pro menor, e no fim os atalhos internos (Mesa/Documentos), sempre disponíveis.
    var destinations: [ExternalVolume] {
        watcher.volumes.filter { !isSource($0) && isClassified($0) }.sorted { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }
            + customFolderVolumes() + internalShortcuts()
    }

    /// Pastas que o usuário escolheu como destino ("Adicionar destino…"). Ficam lembradas; somem da
    /// lista enquanto o disco delas não estiver montado.
    var customFolders: [URL] = (UserDefaults.standard.stringArray(forKey: "cardflow.customFolders") ?? [])
        .map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(customFolders.map(\.path), forKey: "cardflow.customFolders") }
    }
    func customFolderVolumes() -> [ExternalVolume] {
        customFolders.filter { FileManager.default.fileExists(atPath: $0.path) }.map { url in
            let internalDisk = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? true
            return ExternalVolume(url: url, name: url.lastPathComponent, isRemovable: false, isInternal: internalDisk,
                                  totalBytes: nil, physicalDeviceID: PhysicalDisk.wholeDiskBSD(for: url), volumeUUID: nil,
                                  isInternalShortcut: true)
        }
    }

    /// Atalhos fixos de pasta no disco interno (Mesa/Documentos). Compartilham o physicalDeviceID REAL do
    /// disco de sistema → contam como o MESMO disco físico (bloqueia backup entre eles). Cache: o
    /// DiskArbitration roda uma vez, não a cada render.
    @ObservationIgnored private var _internalShortcuts: [ExternalVolume]?
    func internalShortcuts() -> [ExternalVolume] {
        if let cached = _internalShortcuts { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bsd = PhysicalDisk.wholeDiskBSD(for: home) ?? "internal-system-disk"
        func shortcut(_ folder: String, _ name: String) -> ExternalVolume {
            ExternalVolume(url: home.appendingPathComponent(folder), name: name,
                           isRemovable: false, isInternal: true, totalBytes: nil,
                           physicalDeviceID: bsd, volumeUUID: nil, isInternalShortcut: true)
        }
        let result = [shortcut("Desktop", "Mesa"), shortcut("Documents", "Documentos")]
        _internalShortcuts = result
        return result
    }

    func isInternalDestination(_ url: URL?) -> Bool {
        guard let url else { return false }
        return (internalShortcuts() + customFolderVolumes()).contains { $0.url == url && $0.isInternal }
    }
    func volume(_ url: URL?) -> ExternalVolume? {
        guard let url else { return nil }
        return (watcher.volumes + customFolderVolumes() + internalShortcuts()).first { $0.url == url }
    }
    /// Principal e backup são CONFIRMADAMENTE o mesmo disco físico?
    func samePhysicalDisk(_ a: URL?, _ b: URL?) -> Bool {
        guard let pa = volume(a)?.physicalDeviceID, let pb = volume(b)?.physicalDeviceID else { return false }
        return pa == pb
    }
    func confirmedDifferentDisk(_ a: URL?, _ b: URL?) -> Bool {
        guard let pa = volume(a)?.physicalDeviceID, let pb = volume(b)?.physicalDeviceID else { return false }
        return pa != pb
    }
    /// Backup escolhido, mas não dá pra CONFIRMAR que é outro disco físico → avisa.
    var backupNotConfirmed: Bool { backupURL != nil && !confirmedDifferentDisk(backupURL, destinationURL) }
    /// Destinos efetivos: principal + backup (se houver, for outro disco e não o mesmo físico).
    var offloadDestinations: [URL] {
        guard let dest = destinationURL else { return [] }
        if let b = backupURL, b != dest, !samePhysicalDisk(b, dest) { return [dest, b] }
        return [dest]
    }

    /// Marca um disco como CARTÃO (override) e o seleciona.
    func useAsSource(_ v: ExternalVolume) {
        forcedDestinations.remove(v.id); forcedSources.insert(v.id)
        reconcileVolumes()
        selection = .card(v.id)
    }
    /// Marca um disco como DESTINO (corrige falso-positivo da detecção).
    func useAsDestination(_ v: ExternalVolume) {
        forcedSources.remove(v.id); forcedDestinations.insert(v.id)
        reconcileVolumes()
    }

    func start() {
        watcher.start()
        reloadPresets()
        restoreSession()    // destino só se o disco estiver plugado
        reconcileVolumes()  // valida + auto-maior só se a restauração não setou destino
        reloadHistory()
        Notifier.requestAuthorizationIfNeeded()
        formatter.refreshPermission()             // permissão dada nos Ajustes enquanto o app estava fechado
    }

    /// Recentes: registros do principal e do backup ativos.
    func reloadHistory() { history.reload(destinations: offloadDestinations) }

    /// Reconcilia com os volumes atuais: poda overrides órfãos, sincroniza os cartões, conserta destino e
    /// backup pendurados e auto-escolhe o destino. Chamado no start e a cada montagem/desmontagem.
    func reconcileVolumes() {
        let mounted = Set(watcher.volumes.map(\.id))
        forcedSources.formIntersection(mounted)
        forcedDestinations.formIntersection(mounted)
        detectedAsCard = detectedAsCard.filter { mounted.contains($0.key) }
        let srcs = sources, dests = destinations
        if let d = destinationURL, !dests.contains(where: { $0.url == d }) { destinationURL = nil }
        if let b = backupURL, !dests.contains(where: { $0.url == b }) { backupURL = nil }
        // o disco que o usuário escolheu (re)apareceu e o atual é auto → volta pra ele.
        if destWasAutoSelected, let uuid = preferredDestUUID, !uuid.isEmpty,
           let v = dests.first(where: { $0.volumeUUID == uuid }) {
            destinationURL = v.url; destWasAutoSelected = false
        }
        if destinationURL == nil {
            if let uuid = preferredDestUUID, !uuid.isEmpty, let v = dests.first(where: { $0.volumeUUID == uuid }) {
                destinationURL = v.url; destWasAutoSelected = false
            } else {
                // nunca escolhe um cartão sozinho (mesmo marcado como destino pelo usuário): formatar
                // o cartão depois apagaria o próprio backup.
                destinationURL = dests.first(where: { $0.traits?.isCameraMedia != true })?.url
                destWasAutoSelected = (destinationURL != nil)
            }
        }
        if let b = backupURL, b == destinationURL || samePhysicalDisk(b, destinationURL) { backupURL = nil }
        syncCards(with: srcs)
        destinationsChanged()
    }

    /// Escolha EXPLÍCITA de destino pelo usuário: marca o disco preferido, reconcilia e persiste.
    func setUserDestination(_ url: URL?) {
        destinationURL = url
        preferredDestUUID = volume(url)?.volumeUUID
        destWasAutoSelected = false
        reconcileVolumes()
        saveDiskSelection()
        probeInternalPermission(url)
    }

    /// Destino ou backup mudou: atualiza o espaço, os Recentes e as prévias (sem reler os cartões).
    func destinationsChanged() {
        (destinationFreeBytes, destinationTotalBytes) = freeAndTotal(of: destinationURL)
        (backupFreeBytes, backupTotalBytes) = freeAndTotal(of: backupURL)
        recomputeAllPreviews()
    }

    private func freeAndTotal(of url: URL?) -> (Int64?, Int64?) {
        guard let url,
              let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        else { return (nil, nil) }
        // mesmo fallback do motor: exFAT zera a chave "importantUsage" → usa a disponível genérica.
        let free = VolumeFreeSpace.choose(important: v.volumeAvailableCapacityForImportantUsage,
                                          generic: v.volumeAvailableCapacity.map(Int64.init))
        return (free, v.volumeTotalCapacity.map { Int64($0) })
    }

    /// Atalho interno protegido (Mesa/Documentos) dispara o prompt do macOS no 1º acesso: provoca cedo e
    /// detecta negação pra avisar antes de copiar.
    private func probeInternalPermission(_ url: URL?) {
        guard let url, isInternalDestination(url) else { internalPermissionDenied = false; return }
        Task.detached { [weak self] in
            let ok = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            await self?.applyInternalPermissionProbe(url: url, denied: !ok)
        }
    }
    private func applyInternalPermissionProbe(url: URL, denied: Bool) {
        if destinationURL == url { internalPermissionDenied = denied }
    }

    // MARK: Sessão lembrada

    func restoreSession() {
        guard let s = sessionStore.load() else { return }
        if let pid = s.activePresetId, pid != selectedPresetId, presets.contains(where: { $0.id == pid }) {
            pendingProgrammaticPresetId = pid
            selectedPresetId = pid
        }
        if let kind = Preset.Media.Kind(rawValue: s.lastMediaChoice) { defaultMediaChoice = kind }
        if !s.sessionValues.isEmpty { sessionValues = s.sessionValues }
        projectName = activePreset.evento
        preferredDestUUID = s.destinationBindings["principal"]?.volumeUUID
        let bindables = watcher.volumes + customFolderVolumes() + internalShortcuts()
        if let d = s.destinationBindings["principal"]?.resolve(in: bindables) { destinationURL = d }
        if let b = s.destinationBindings["backup"]?.resolve(in: bindables) { backupURL = b }
    }

    /// Persiste a escolha de DISCO: só quando o usuário escolhe (não na auto-seleção nem na restauração).
    func saveDiskSelection() {
        var s = sessionStore.load() ?? Session()
        s.destinationBindings = ["principal": binding(for: destinationURL), "backup": binding(for: backupURL)]
            .compactMapValues { $0 }
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = defaultMediaChoice.rawValue
        s.sessionValues = sessionValues
        try? sessionStore.save(s)
    }

    /// Persiste modelo/mídia/campos PRESERVANDO os discos lembrados.
    func savePresetSelection() {
        var s = sessionStore.load() ?? Session()
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = defaultMediaChoice.rawValue
        s.sessionValues = sessionValues
        try? sessionStore.save(s)
    }

    private func binding(for url: URL?) -> DiskBinding? {
        guard let url, let v = volume(url) else { return nil }
        let uuid = (v.volumeUUID?.isEmpty == false) ? v.volumeUUID : nil   // UUID vazio = ausente
        return DiskBinding(volumeUUID: uuid, lastKnownPath: v.url.path)
    }

    // MARK: Modelos

    func importPreset(from url: URL) throws {
        var p = try presetStore.load(from: url)
        let existing = Set(((try? presetStore.list()) ?? []).map(\.id))
        // não sombrear built-ins NEM sobrescrever um modelo salvo de mesmo id → entra como novo
        if p.id == "factory-default" || p.id == "flat-default" || existing.contains(p.id) {
            p.id = UUID().uuidString
        }
        try presetStore.save(p)
        reloadPresets(selecting: p.id)
    }

    func exportActivePreset(to url: URL) throws {
        try presetStore.export(activePreset, to: url)
    }

    func duplicateActivePreset() {
        if let id = duplicatePreset(selectedPresetId) { reloadPresets(selecting: id) }
    }

    func deleteActivePreset() { deletePresets([selectedPresetId]) }

    /// Recarrega a lista (fábrica + salvos) e, opcionalmente, seleciona um modelo.
    func reloadPresets(selecting id: String? = nil, preserveContext: Bool = false) {
        presets = [.factoryDefault] + ((try? presetStore.list()) ?? [])
        if let id, id != selectedPresetId, presets.contains(where: { $0.id == id }) {
            if preserveContext { pendingProgrammaticPresetId = id }
            selectedPresetId = id
        }
        if projectName.trimmingCharacters(in: .whitespaces).isEmpty { projectName = activePreset.evento }
        let validKeys = Set(activePreset.sessionFields.map { $0.key })   // poda campos órfãos
        sessionValues = sessionValues.filter { validKeys.contains($0.key) }
        recomputeAllPreviews()
    }

    /// Chamado pelo onChange de selectedPresetId. Troca MANUAL reseta o projeto e os campos pro padrão
    /// do modelo; troca programática (restore/editor) preserva o que foi digitado.
    func presetSelectionChanged() {
        if selectedPresetId == pendingProgrammaticPresetId {
            pendingProgrammaticPresetId = nil
            previewPresetOverride = nil
            recomputeAllPreviews()
            return
        }
        pendingProgrammaticPresetId = nil
        previewPresetOverride = nil
        projectName = activePreset.evento
        sessionValues = [:]
        recomputeAllPreviews()
        savePresetSelection()
    }

    // MARK: Filtro de data (cálculo puro)

    nonisolated static func captureDateInterval(for filter: CaptureDateFilter,
                                                calendar: Calendar = .current) -> DateInterval? {
        func wholeDay(_ date: Date) -> DateInterval {
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        }
        switch filter {
        case .all:
            return nil
        case .today(let anchor), .singleDay(let anchor):
            return wholeDay(anchor)
        case .range(let a, let b):
            let (s, e) = a <= b ? (a, b) : (b, a)
            let start = calendar.startOfDay(for: s)
            let endStart = calendar.startOfDay(for: e)
            let end = calendar.date(byAdding: .day, value: 1, to: endStart) ?? endStart.addingTimeInterval(86_400)
            return DateInterval(start: start, end: end)
        }
    }

    static func captureDateFilterTitle(_ filter: CaptureDateFilter) -> String {
        func short(_ d: Date) -> String { d.formatted(.dateTime.day().month().year()) }
        switch filter {
        case .all: return String(localized: "main.captureFilter.all")
        case .today(let anchor):
            return Calendar.current.isDateInToday(anchor) ? String(localized: "main.captureFilter.today") : short(anchor)
        case .singleDay(let date): return short(date)
        case .range(let a, let b):
            let (s, e) = a <= b ? (a, b) : (b, a)
            return "\(short(s)) \(String(localized: "main.captureFilter.rangeSeparator")) \(short(e))"
        }
    }

    // Os erros do OffloadKit cravam a mensagem em pt-BR (fallback de dev / CLI). Na UI do app remapeamos
    // cada caso pro catálogo localizado.
    nonisolated static func localizedMessage(for error: OffloadError) -> String {
        switch error {
        case .notEnoughSpace(let shortfalls):
            let names = shortfalls.map { $0.destination.lastPathComponent }.joined(separator: ", ")
            return String(localized: "error.offload.notEnoughSpace \(names)")
        case .unsafeDestination: return String(localized: "error.offload.unsafeDestination")
        case .cancelled: return String(localized: "error.offload.cancelled")
        case .diskFullDuringCopy: return String(localized: "error.offload.diskFullDuringCopy")
        case .permissionDenied: return String(localized: "error.offload.permissionDenied")
        }
    }

    nonisolated static func localizedMessage(for error: NamingError) -> String {
        switch error {
        case .unknownToken(let token): return String(localized: "error.naming.unknownToken \(token)")
        case .unknownModifier(let modifier): return String(localized: "error.naming.unknownModifier \(modifier)")
        case .pathTraversal: return String(localized: "error.naming.pathTraversal")
        }
    }
}
