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
    case completed(String)     // CompletedCard.id (cartão que terminou e saiu do Mac)
}

/// Estado do PROJETO (modelo, destinos, nome, campos) e a coleção de cartões conectados. O estado de
/// cada cartão mora no seu `CardSession`; a cópia, a formatação e a leitura ficam nas extensões
/// `AppModel+Cards`, `AppModel+Offload` e `AppModel+Format`.
@MainActor @Observable
final class AppModel {
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
        var wholeDiskBytes: UInt64? = nil
        var camera: String = ""
        /// Cartão com várias câmeras: câmera de cada grupo de origem.
        var cameras: [String: String] = [:]
        var sessionValues: [String: String] = [:]
        var fastResume = true
        var formatWhenDone = false
        var ejectWhenDone = true
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
        if !detectInBackground {
            resolvedCustomFolders = Self.resolveCustomFoldersSync(customFolders)
        }
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
    func card(sessionID: String) -> CardSession? { cards.first { $0.sessionID.uuidString == sessionID } }
    /// Cartões que terminaram e saíram do Mac nesta sessão, o mais recente primeiro (resumo na tela).
    var completed: [CompletedCard] = []
    func completedCard(id: String) -> CompletedCard? { completed.first { $0.id == id } }

    @ObservationIgnored var batchCount = 0        // cartões na leva atual da fila
    @ObservationIgnored var batchSucceeded = 0    // cartões que concluíram com sucesso na leva
    @ObservationIgnored lazy var queue = CopyQueue { [weak self] sessionID in
        await self?.runOffload(sessionID: sessionID)
    }

    // MARK: Projeto

    /// "Formatar ao terminar": por sessão, sempre desligado quando o app abre (decisão do dono).
    var autoFormatThisSession = false
    /// "Ejetar ao terminar": reativo via `@Observable` e persistido em `UserDefaults`.
    var ejectWhenDone: Bool = (UserDefaults.standard.object(forKey: "cardflow.ejectWhenDone") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(ejectWhenDone, forKey: "cardflow.ejectWhenDone") }
    }
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
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastHistoryDestinations: [URL] = []

    // MARK: Destinos

    var destinationURL: URL?          // disco principal
    var backupURL: URL?               // disco de backup (opcional; copia conferida em paralelo)
    var preferredDestUUID: String?    // disco que o USUÁRIO escolheu (por UUID), sticky a desmonte transitório
    var preferredBackupUUID: String?  // disco de backup lembrado (por UUID), sticky à classificação inicial
    @ObservationIgnored var destWasAutoSelected = false
    var internalPermissionDenied = false   // macOS bloqueou acesso à pasta interna escolhida (Mesa/Documentos)
    var forcedSources: Set<String> = []        // discos que o usuário marcou como cartão
    var forcedDestinations: Set<String> = []   // discos que o usuário marcou como destino
    /// Discos físicos com formatação em curso (garante que o volume vazio de leitor USB volte como fonte).
    @ObservationIgnored var formattingWholeDiskBSDs: Set<String> = []
    /// Cache da detecção por conteúdo (lê o disco): por volume montado, podado quando ele sai.
    @ObservationIgnored var detectedAsCard: [String: Bool] = [:]

    /// Cache de espaço livre/total por caminho normalizado (preenchido fora da thread principal).
    var diskSpaces: [String: DiskSpace] = [:]
    @ObservationIgnored private var diskSpaceTask: Task<Void, Never>?

    /// Cache de pastas personalizadas resolvidas (sem I/O nem DiskArbitration na main thread).
    var resolvedCustomFolders: [ExternalVolume] = []
    @ObservationIgnored private var customFoldersTask: Task<Void, Never>?

    /// Detecção por conteúdo em segundo plano (padrão). Abrir a raiz de um volume pode esperar a permissão
    /// do macOS ("volume removível") e isso nunca pode travar a janela. Nos testes é síncrona.
    @ObservationIgnored var detectInBackground = !AppModel.runningTests
    @ObservationIgnored private var classifying: Set<String> = []
    static let runningTests: Bool = {
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("testing") || Bundle.main.bundlePath.hasSuffix(".xctest")
    }()

    /// Normaliza URL de pasta removendo barra final para igualdade consistente entre `NSOpenPanel` e `UserDefaults`.
    nonisolated static func normalizeFolderURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    /// Espaço em disco em cache (sem I/O síncrono no `body` do SwiftUI).
    func diskSpace(for url: URL?) -> DiskSpace? {
        guard let url else { return nil }
        let key = Self.normalizeFolderURL(url).path
        if let cached = diskSpaces[key] { return cached }
        if !detectInBackground, let space = DiskSpace(url: url) {
            return space
        }
        return nil
    }

    /// Atualiza o cache de espaço em disco de todos os destinos em segundo plano.
    func refreshDiskSpaces() {
        let urls = Array(Set(destinations.map { Self.normalizeFolderURL($0.url) }))
        guard !detectInBackground else {
            diskSpaceTask?.cancel()
            diskSpaceTask = Task.detached { [weak self] in
                var map: [String: DiskSpace] = [:]
                for u in urls {
                    if Task.isCancelled { return }
                    if let s = DiskSpace(url: u) { map[u.path] = s }
                }
                let finalMap = map
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.diskSpaces = finalMap
                }
            }
            return
        }
        var map: [String: DiskSpace] = [:]
        for u in urls { if let s = DiskSpace(url: u) { map[u.path] = s } }
        diskSpaces = map
    }

    /// É cartão (fonte)? Overrides do usuário, formatação em curso, tipo físico ou conteúdo.
    func isSource(_ v: ExternalVolume) -> Bool {
        if let bsd = v.physicalDeviceID, formattingWholeDiskBSDs.contains(bsd) { return true }
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
        if let bsd = v.physicalDeviceID, formattingWholeDiskBSDs.contains(bsd) { return true }
        return forcedSources.contains(v.id) || forcedDestinations.contains(v.id) || detectedAsCard[v.id] != nil
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

    /// Pastas que o usuário escolheu como destino ("Adicionar destino…"). Normalizadas sem barra final.
    var customFolders: [URL] = Array(NSOrderedSet(array: (UserDefaults.standard.stringArray(forKey: "cardflow.customFolders") ?? [])
        .map { AppModel.normalizeFolderURL(URL(fileURLWithPath: $0)) })) as? [URL] ?? [] {
        didSet {
            UserDefaults.standard.set(customFolders.map(\.path), forKey: "cardflow.customFolders")
            refreshCustomFolders()
        }
    }

    func refreshCustomFolders() {
        let folders = customFolders
        guard detectInBackground else {
            resolvedCustomFolders = Self.resolveCustomFoldersSync(folders)
            return
        }
        customFoldersTask?.cancel()
        customFoldersTask = Task.detached { [weak self] in
            let resolved = Self.resolveCustomFoldersSync(folders)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.resolvedCustomFolders = resolved
                self.refreshDiskSpaces()
            }
        }
    }

    private nonisolated static func resolveCustomFoldersSync(_ folders: [URL]) -> [ExternalVolume] {
        folders.filter { FileManager.default.fileExists(atPath: $0.path) }.map { raw in
            let url = normalizeFolderURL(raw)
            let internalDisk = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? true
            return ExternalVolume(url: url, name: url.lastPathComponent, isRemovable: false, isInternal: internalDisk,
                                  totalBytes: nil, physicalDeviceID: PhysicalDisk.wholeDiskBSD(for: url), volumeUUID: nil,
                                  isInternalShortcut: true)
        }
    }

    func customFolderVolumes() -> [ExternalVolume] { resolvedCustomFolders }

    /// Atalhos fixos de pasta no disco interno (Desktop/Documents no idioma do macOS). Compartilham o
    /// physicalDeviceID REAL do disco de sistema -> bloqueia backup entre eles.
    @ObservationIgnored private var _internalShortcuts: [ExternalVolume]?
    func internalShortcuts() -> [ExternalVolume] {
        if let cached = _internalShortcuts { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bsd = PhysicalDisk.wholeDiskBSD(for: home) ?? "internal-system-disk"
        func shortcut(_ folder: String) -> ExternalVolume {
            let url = Self.normalizeFolderURL(home.appendingPathComponent(folder))
            let localizedName = FileManager.default.displayName(atPath: url.path)
            return ExternalVolume(url: url, name: localizedName.isEmpty ? folder : localizedName,
                                  isRemovable: false, isInternal: true, totalBytes: nil,
                                  physicalDeviceID: bsd, volumeUUID: nil, isInternalShortcut: true)
        }
        let result = [shortcut("Desktop"), shortcut("Documents")]
        _internalShortcuts = result
        return result
    }

    func isInternalDestination(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = Self.normalizeFolderURL(url).path
        return (internalShortcuts() + customFolderVolumes()).contains { $0.url.path == path && $0.isInternal }
    }
    func volume(_ url: URL?) -> ExternalVolume? {
        guard let url else { return nil }
        let path = Self.normalizeFolderURL(url).path
        return (watcher.volumes + customFolderVolumes() + internalShortcuts()).first { $0.url.path == path }
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
    /// Backup escolhido, mas não dá pra CONFIRMAR que é outro disco físico -> avisa.
    var backupNotConfirmed: Bool { backupURL != nil && !confirmedDifferentDisk(backupURL, destinationURL) }
    /// Destinos efetivos: principal + backup (se houver, for outro disco e não o mesmo físico).
    var offloadDestinations: [URL] {
        guard let dest = destinationURL else { return [] }
        if let b = backupURL, Self.normalizeFolderURL(b).path != Self.normalizeFolderURL(dest).path, !samePhysicalDisk(b, dest) {
            return [dest, b]
        }
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
        guard !started else { return }
        started = true
        watcher.start()
        refreshCustomFolders()
        reloadPresets()
        restoreSession()    // destino só se o disco estiver plugado
        reconcileVolumes()  // valida + auto-maior só se a restauração não setou destino
        if !offloadDestinations.isEmpty && !hasUnclassifiedVolumes {
            reloadHistory()
        }
        Notifier.requestAuthorizationIfNeeded()
        formatter.refreshPermission()             // permissão dada nos Ajustes enquanto o app estava fechado
    }

    private var hasUnclassifiedVolumes: Bool {
        watcher.volumes.contains { !isClassified($0) }
    }

    /// Recentes: registros do principal e do backup ativos.
    func reloadHistory() {
        lastHistoryDestinations = offloadDestinations
        history.reload(destinations: offloadDestinations)
    }

    /// Reconcilia com os volumes atuais: poda overrides órfãos, sincroniza os cartões, conserta destino e
    /// backup pendurados e auto-escolhe o destino. Chamado no start e a cada montagem/desmontagem.
    func reconcileVolumes() {
        let mounted = Set(watcher.volumes.map(\.id))
        forcedSources.formIntersection(mounted)
        forcedDestinations.formIntersection(mounted)
        detectedAsCard = detectedAsCard.filter { mounted.contains($0.key) }

        // Dispara classificação de volumes recém-chegados antes de checar `destinations`
        let srcs = sources
        let dests = destinations
        let destPaths = Set(dests.map { Self.normalizeFolderURL($0.url).path })
        let stillClassifying = hasUnclassifiedVolumes

        // Enquanto discos externos ainda estão sendo classificados na abertura, não descarta
        // destinos restaurados que já estão montados nem cai prematuramente em Mesa/Documentos.
        if let d = destinationURL {
            let p = Self.normalizeFolderURL(d).path
            let pendingMount = stillClassifying && watcher.volumes.contains { Self.normalizeFolderURL($0.url).path == p }
            if !destPaths.contains(p) && !pendingMount { destinationURL = nil }
        }
        if let b = backupURL {
            let p = Self.normalizeFolderURL(b).path
            let pendingMount = stillClassifying && watcher.volumes.contains { Self.normalizeFolderURL($0.url).path == p }
            if !destPaths.contains(p) && !pendingMount { backupURL = nil }
        }

        // Restaura backup preferido quando o volume terminar de classificar ou reconectar.
        if backupURL == nil, let bUUID = preferredBackupUUID, !bUUID.isEmpty,
           let bv = dests.first(where: { $0.volumeUUID == bUUID }) {
            backupURL = bv.url
        }

        // O disco principal que o usuário escolheu (re)apareceu e o atual é auto -> volta pra ele.
        if destWasAutoSelected, let uuid = preferredDestUUID, !uuid.isEmpty,
           let v = dests.first(where: { $0.volumeUUID == uuid }) {
            destinationURL = v.url; destWasAutoSelected = false
        }
        if destinationURL == nil {
            if let uuid = preferredDestUUID, !uuid.isEmpty, let v = dests.first(where: { $0.volumeUUID == uuid }) {
                destinationURL = v.url; destWasAutoSelected = false
            } else if !stillClassifying {
                // Nunca escolhe um cartão sozinho nem o disco já escolhido como backup.
                let candidate = dests.first { v in
                    v.traits?.isCameraMedia != true
                        && (backupURL == nil || (Self.normalizeFolderURL(v.url).path != Self.normalizeFolderURL(backupURL!).path
                                                 && !samePhysicalDisk(v.url, backupURL)))
                }
                destinationURL = candidate?.url
                destWasAutoSelected = (destinationURL != nil)
            }
        }
        if let b = backupURL, let d = destinationURL,
           Self.normalizeFolderURL(b).path == Self.normalizeFolderURL(d).path || samePhysicalDisk(b, d) {
            backupURL = nil
        }
        syncCards(with: srcs)
        destinationsChanged()
    }

    /// Escolha EXPLÍCITA de destino pelo usuário: marca o disco preferido, reconcilia e persiste.
    func setUserDestination(_ url: URL?) {
        let norm = url.map(Self.normalizeFolderURL)
        destinationURL = norm
        preferredDestUUID = volume(norm)?.volumeUUID
        destWasAutoSelected = false
        reconcileVolumes()
        saveDiskSelection()
        probeInternalPermissions()
    }

    /// Destino ou backup mudou: atualiza o espaço (em background), os Recentes e as prévias.
    func destinationsChanged() {
        refreshDiskSpaces()
        if offloadDestinations != lastHistoryDestinations && !hasUnclassifiedVolumes {
            reloadHistory()
        }
        probeInternalPermissions()
        recomputeAllPreviews()
    }

    /// Atalho interno protegido (Mesa/Documentos) dispara o prompt do macOS no 1º acesso: provoca cedo e
    /// detecta negação pra avisar antes de copiar (vale tanto para Principal quanto para Backup).
    func probeInternalPermissions() {
        let internals = offloadDestinations.filter { isInternalDestination($0) }
        guard !internals.isEmpty else { internalPermissionDenied = false; return }
        let expected = Set(internals.map { Self.normalizeFolderURL($0).path })
        Task.detached { [weak self] in
            let allOK = internals.allSatisfy { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
            await self?.applyInternalPermissionProbe(paths: expected, denied: !allOK)
        }
    }
    private func applyInternalPermissionProbe(paths: Set<String>, denied: Bool) {
        let current = Set(offloadDestinations.filter { isInternalDestination($0) }.map { Self.normalizeFolderURL($0).path })
        if current == paths { internalPermissionDenied = denied }
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
        preferredBackupUUID = s.destinationBindings["backup"]?.volumeUUID
        let bindables = watcher.volumes + customFolderVolumes() + internalShortcuts()
        if let d = s.destinationBindings["principal"]?.resolve(in: bindables) { destinationURL = Self.normalizeFolderURL(d) }
        if let b = s.destinationBindings["backup"]?.resolve(in: bindables) { backupURL = Self.normalizeFolderURL(b) }
    }

    /// Persiste a escolha de DISCO: só quando o usuário escolhe (não na auto-seleção nem na restauração).
    func saveDiskSelection() {
        var s = sessionStore.load() ?? Session()
        s.destinationBindings = ["principal": binding(for: destinationURL), "backup": binding(for: backupURL)]
            .compactMapValues { $0 }
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = defaultMediaChoice.rawValue
        s.sessionValues = sessionValues
        _ = try? sessionStore.save(s)
    }

    /// Persiste modelo/mídia/campos PRESERVANDO os discos lembrados.
    func savePresetSelection() {
        var s = sessionStore.load() ?? Session()
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = defaultMediaChoice.rawValue
        s.sessionValues = sessionValues
        _ = try? sessionStore.save(s)
    }

    private func binding(for url: URL?) -> DiskBinding? {
        guard let url, let v = volume(url) else { return nil }
        let uuid = (v.volumeUUID?.isEmpty == false) ? v.volumeUUID : nil   // UUID vazio = ausente
        return DiskBinding(volumeUUID: uuid, lastKnownPath: Self.normalizeFolderURL(v.url).path)
    }

    // MARK: Modelos

    func importPreset(from url: URL) throws {
        var p = try presetStore.load(from: url)
        let existing = Set(((try? presetStore.list()) ?? []).map(\.id))
        // não sombrear built-ins NEM sobrescrever um modelo salvo de mesmo id -> entra como novo
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
        liveSaveTask?.cancel()
        liveSaveTask = nil
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
