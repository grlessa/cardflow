import Foundation
import AppKit
import OffloadKit

@MainActor @Observable
final class AppModel {
    enum OffloadState: Equatable {
        case idle
        case running(OffloadProgress)
        case finished(OffloadOutcome)
        case failed(String, cardUncertain: Bool)   // cardUncertain: falhou DURANTE a cópia → avisar p/ não formatar
    }

    let watcher = VolumeWatcher()
    let presetStore = PresetStore(directory: PresetStore.appPresetsDirectory())
    let sessionStore = SessionStore(fileURL: SessionStore.appSessionFile())

    var presets: [Preset] = []
    var selectedPresetId: String = Preset.factoryDefault.id
    var destinationURL: URL?          // disco principal
    var backupURL: URL?               // disco de backup (opcional; copia verificada em paralelo)
    var preferredDestUUID: String?    // disco que o USUÁRIO escolheu (por UUID) — sticky a desmonte transitório
    private var destWasAutoSelected = false   // destino atual veio de auto-seleção, não da escolha do usuário
    var camera: String = "Cam01"
    var mediaChoice: Preset.Media.Kind = .both
    var filterTodayOnly = false        // "só hoje": copia só o que foi capturado hoje (vários domingos no mesmo disco)
    /// Início de hoje (fuso local) quando o filtro está ligado; senão sem filtro.
    var capturedSince: Date? { filterTodayOnly ? Calendar.current.startOfDay(for: Date()) : nil }
    var state: OffloadState = .idle
    var cardPreview: OffloadPreview?   // prévia do cartão detectado (contagem/tamanho)
    var internalPermissionDenied = false   // macOS bloqueou acesso à pasta interna escolhida (Mesa/Documentos)
    var acknowledgedIncompleteLote: Int?   // número do lote incompleto que o usuário JÁ confirmou entender
    var eventName: String = ""                   // pasta-mãe (sobrescreve o evento do preset nesta sessão)
    var sessionValues: [String: String] = [:]    // valores de campos personalizados do preset
    var destinationFreeBytes: Int64?
    var destinationTotalBytes: Int64?
    var backupFreeBytes: Int64?
    var backupTotalBytes: Int64?
    var cardEjected = false            // cartão foi ejetado automaticamente ao terminar com sucesso
    var ejectError: String?           // ejeção falhou (disco ocupado) → avisa pra ejetar à mão
    var offloadStartedAt: Date?       // início da transferência (cronômetro ao vivo)
    var lastElapsed: TimeInterval?    // duração total da última transferência (mostrada no fim)
    var forcedSources: Set<String> = []        // discos que o usuário marcou como fonte (override)
    var forcedDestinations: Set<String> = []   // discos que o usuário marcou como destino (override)
    var selectedCardURL: URL?                  // qual fonte está ativa quando há várias
    private var previewGeneration = 0   // descarta prévias de cartão obsoletas (last-writer-wins)
    private var previewedCardURL: URL?  // a fonte que a prévia atual representa (pra limpar ao trocar)
    private var previewedDestinations: [URL] = []   // destinos da prévia atual (pra recalcular espaço ao trocar)
    private var pendingProgrammaticPresetId: String?   // id setado por restore/editor; o onChange compara por VALOR (não vaza)
    private var offloadTask: Task<Void, Never>?     // a transferência em andamento (pra poder cancelar)
    var isCancelling = false                        // o usuário clicou Parar e estamos encerrando (feedback)

    var activePreset: Preset {
        presets.first { $0.id == selectedPresetId } ?? .factoryDefault
    }

    /// É fonte de mídia? auto-detecção (CardDetection: marcador OU mídia solta na raiz) + overrides do usuário.
    func isSource(_ v: ExternalVolume) -> Bool {
        if forcedDestinations.contains(v.id) { return false }
        if forcedSources.contains(v.id) { return true }
        return CardDetection.isCard(v)
    }
    /// Fontes conectadas (cartões/gravadores) e discos de destino, com overrides aplicados.
    var sources: [ExternalVolume] { watcher.volumes.filter { isSource($0) } }
    /// Destinos do MAIOR pro menor — o destino tende a ser o disco grande, então o padrão acerta.
    /// No fim entram os atalhos internos (Mesa/Documentos), sempre disponíveis.
    var destinations: [ExternalVolume] {
        watcher.volumes.filter { !isSource($0) }.sorted { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }
            + internalShortcuts()
    }

    /// Atalhos fixos de pasta no disco interno (Mesa/Documentos) que aparecem como destino. Não vêm do
    /// VolumeWatcher (que só lista /Volumes/); são injetados aqui. Os dois compartilham o physicalDeviceID
    /// REAL do disco de sistema → contam como o MESMO disco físico (bloqueia backup entre eles).
    /// Cache: homeDir e o disco de sistema não mudam na sessão, então o DiskArbitration (wholeDiskBSD)
    /// roda UMA vez, não a cada render (destinations é uma propriedade computada lida pelo SwiftUI).
    @ObservationIgnored private var _internalShortcuts: [ExternalVolume]?
    private func internalShortcuts() -> [ExternalVolume] {
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

    /// É um dos atalhos internos? (decide a reserva de 5GB na checagem de espaço).
    func isInternalDestination(_ url: URL?) -> Bool {
        guard let url else { return false }
        return internalShortcuts().contains { $0.url == url }
    }

    /// A fonte ativa (a selecionada, ou a primeira detectada).
    var detectedCard: ExternalVolume? {
        let srcs = sources
        if let sel = selectedCardURL, let s = srcs.first(where: { $0.url == sel }) { return s }
        return srcs.first
    }

    /// Marca um disco como FONTE (override do auto-detect) e o seleciona.
    func useAsSource(_ v: ExternalVolume) {
        forcedDestinations.remove(v.id); forcedSources.insert(v.id)
        selectedCardURL = v.url
        reconcileVolumes()   // v saiu dos destinos → reconcilia destino/backup
    }
    /// Marca um disco como DESTINO (não é fonte) — corrige falso-positivo da detecção.
    func useAsDestination(_ v: ExternalVolume) {
        forcedSources.remove(v.id); forcedDestinations.insert(v.id)
        reconcileVolumes()   // v saiu das fontes → reconcilia seleção/destino
    }
    var canStart: Bool {
        if case .running = state { return false }
        guard detectedCard != nil, destinationURL != nil else { return false }
        if internalPermissionDenied { return false }   // macOS bloqueou a pasta interna → não deixa iniciar
        if loteLossUnconfirmed { return false }         // lote anterior incompleto não confirmado → trava
        // sem prévia ainda (checagem de espaço em andamento) → não habilita ainda (evita iniciar às cegas)
        guard let sf = cardPreview?.shortfalls else { return false }
        return sf.isEmpty   // não deixa iniciar com disco sem espaço
    }
    /// Há um lote anterior incompleto detectado e ainda não confirmado pelo usuário? (trava o início).
    /// Compara o NÚMERO do lote incompleto com o que foi confirmado — assim um transitório de I/O
    /// (detecção some por um instante) não apaga a confirmação, e um lote incompleto diferente
    /// (outro cartão) exige nova confirmação.
    var loteLossUnconfirmed: Bool {
        if let inc = cardPreview?.lote?.anteriorIncompleto { return inc != acknowledgedIncompleteLote }
        return false
    }
    /// Algum destino (principal/backup) não cabe? Usa a checagem do motor (com margem real).
    func hasShortfall(_ url: URL?) -> Bool {
        guard let url, let sf = cardPreview?.shortfalls else { return false }
        return sf.contains { $0.destination == url }
    }
    var principalTooSmall: Bool { hasShortfall(destinationURL) }
    /// É uma RETOMADA? Parte deste evento já está gravada+conferida no destino, e ainda falta copiar.
    /// O botão vira "Retomar" pra o usuário confiar que o sistema entendeu que era pra continuar.
    var isResume: Bool {
        guard let pv = cardPreview else { return false }
        return pv.alreadyPresent > 0 && pv.alreadyPresent < pv.selectedCount
    }
    /// Está copiando? (pra travar os controles durante o processo)
    var isBusy: Bool { if case .running = state { return true }; return false }
    /// Pasta-mãe efetiva (o que o usuário digitou, ou o evento do preset), saneada:
    /// "Culto 09/06" vira "Culto 09-06" pra não criar subpasta acidental — e bater com
    /// o que o token {evento} produz (que o motor já saneia).
    var effectiveEvento: String {
        let e = eventName.trimmingCharacters(in: .whitespaces)
        return NameBuilder.sanitizePathComponent(e.isEmpty ? activePreset.evento : e)
    }
    /// O preset ativo usa {camera}? (pra mostrar o campo Câmera só quando faz diferença)
    var usesCameraToken: Bool {
        let p = activePreset
        if p.folderStructure.contains("{camera}") { return true }
        return p.rename.enabled && p.rename.template.contains("{camera}")
    }
    private func volume(_ url: URL?) -> ExternalVolume? {
        guard let url else { return nil }
        return (watcher.volumes + internalShortcuts()).first { $0.url == url }
    }
    /// Principal e backup são CONFIRMADAMENTE o mesmo disco físico? (só true quando os dois IDs existem e batem)
    func samePhysicalDisk(_ a: URL?, _ b: URL?) -> Bool {
        guard let pa = volume(a)?.physicalDeviceID, let pb = volume(b)?.physicalDeviceID else { return false }
        return pa == pb
    }
    /// Confirmadamente discos físicos DIFERENTES? (só true quando os dois IDs existem e diferem)
    func confirmedDifferentDisk(_ a: URL?, _ b: URL?) -> Bool {
        guard let pa = volume(a)?.physicalDeviceID, let pb = volume(b)?.physicalDeviceID else { return false }
        return pa != pb
    }
    /// Backup escolhido, mas não dá pra CONFIRMAR que é outro disco físico → avisa (pode não ser redundante).
    var backupNotConfirmed: Bool { backupURL != nil && !confirmedDifferentDisk(backupURL, destinationURL) }

    /// Destinos efetivos do offload: principal + backup (se houver, for outro disco E não-mesmo-físico).
    var offloadDestinations: [URL] {
        guard let dest = destinationURL else { return [] }
        if let b = backupURL, b != dest, !samePhysicalDisk(b, dest) { return [dest, b] }
        return [dest]
    }
    /// O backup escolhido não tem espaço pro cartão? (mesma checagem do motor, com margem real)
    var backupTooSmall: Bool { hasShortfall(backupURL) }

    private func freeAndTotal(of url: URL?) -> (Int64?, Int64?) {
        guard let url,
              let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        else { return (nil, nil) }
        // mesmo fallback do motor: exFAT zera a chave "importantUsage" → usa a disponível genérica,
        // senão a barra de capacidade mostraria 0 livre num SSD exFAT cheio de espaço.
        let free = VolumeFreeSpace.choose(important: v.volumeAvailableCapacityForImportantUsage,
                                          generic: v.volumeAvailableCapacity.map(Int64.init))
        return (free, v.volumeTotalCapacity.map { Int64($0) })
    }

    func start() {
        watcher.start()
        reloadPresets()
        restoreSession()    // restaura o que foi lembrado (destino só se o disco estiver plugado)
        reconcileVolumes()  // valida + auto-maior só se a restauração não setou destino
        Notifier.requestAuthorizationIfNeeded()   // pra avisar quando o offload terminar (a pessoa sai de perto)
    }

    /// Restaura preset/destino/backup/mídia da última sessão (uma vez, no start, após presets+volumes).
    func restoreSession() {
        guard let s = sessionStore.load() else { return }
        if let pid = s.activePresetId, pid != selectedPresetId, presets.contains(where: { $0.id == pid }) {
            pendingProgrammaticPresetId = pid    // troca programática; se o onChange disparar, preserva o contexto
            selectedPresetId = pid
        }
        if let kind = Preset.Media.Kind(rawValue: s.lastMediaChoice) { mediaChoice = kind }
        if !s.sessionValues.isEmpty { sessionValues = s.sessionValues }
        eventName = activePreset.evento   // Pasta = evento do preset RESTAURADO (não fica preso no default)
        preferredDestUUID = s.destinationBindings["principal"]?.volumeUUID   // sticky mesmo se não plugado agora
        let bindables = watcher.volumes + internalShortcuts()   // resolve atalhos internos por caminho também
        if let d = s.destinationBindings["principal"]?.resolve(in: bindables) { destinationURL = d }
        if let b = s.destinationBindings["backup"]?.resolve(in: bindables) { backupURL = b }
    }

    /// Persiste a escolha de DISCO — chamado SÓ quando o usuário escolhe um disco no seletor (NÃO na
    /// auto-seleção nem na restauração). Assim um disco desplugado / auto-fallback nunca apaga o disco
    /// que o usuário escolheu (a auto-seleção mexe em destinationURL direto, fora do seletor).
    func saveDiskSelection() {
        var s = sessionStore.load() ?? Session()
        s.destinationBindings = ["principal": binding(for: destinationURL), "backup": binding(for: backupURL)]
            .compactMapValues { $0 }
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = mediaChoice.rawValue
        s.sessionValues = sessionValues
        try? sessionStore.save(s)
    }

    /// Persiste preset/mídia/campos PRESERVANDO os discos lembrados — não recalcula bindings, então uma
    /// troca de preset/mídia (ou no launch) com disco auto-selecionado não sobrescreve o disco do usuário.
    func savePresetSelection() {
        var s = sessionStore.load() ?? Session()
        s.activePresetId = selectedPresetId
        s.lastMediaChoice = mediaChoice.rawValue
        s.sessionValues = sessionValues
        try? sessionStore.save(s)
    }

    private func binding(for url: URL?) -> DiskBinding? {
        guard let url, let v = (watcher.volumes + internalShortcuts()).first(where: { $0.url == url }) else { return nil }
        let uuid = (v.volumeUUID?.isEmpty == false) ? v.volumeUUID : nil   // UUID vazio = ausente (evita falso-match)
        return DiskBinding(volumeUUID: uuid, lastKnownPath: v.url.path)   // atalho interno: UUID nil → casa por caminho
    }

    func importPreset(from url: URL) throws {
        var p = try presetStore.load(from: url)
        let existing = Set(((try? presetStore.list()) ?? []).map(\.id))
        // não sombrear built-ins NEM sobrescrever um preset salvo de mesmo id → entra como novo
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
        let d = activePreset.duplicated(newName: "\(activePreset.name) (cópia)")
        _ = try? presetStore.save(d)
        reloadPresets(selecting: d.id)   // muda selectedPresetId → presetSelectionChanged lembra o preset
    }

    func deleteActivePreset() {
        guard selectedPresetId != "factory-default" else { return }
        try? presetStore.delete(id: selectedPresetId)
        reloadPresets(selecting: "factory-default")
    }

    /// Reconcilia o estado com os volumes atuais: poda overrides órfãos, conserta destino/backup/fonte
    /// pendurados (disco desconectado ou que virou outro papel), auto-seleciona o destino. Chamado no
    /// start e SEMPRE que os volumes montados mudam (mount/unmount/rename).
    func reconcileVolumes() {
        let mounted = Set(watcher.volumes.map(\.id))
        forcedSources.formIntersection(mounted)        // override gruda no path → poda o que sumiu
        forcedDestinations.formIntersection(mounted)
        let srcs = sources, dests = destinations
        if let sel = selectedCardURL, !srcs.contains(where: { $0.url == sel }) { selectedCardURL = nil }
        if let d = destinationURL, !dests.contains(where: { $0.url == d }) { destinationURL = nil }  // desconectou / virou fonte
        if let b = backupURL, !dests.contains(where: { $0.url == b }) { backupURL = nil }
        // o disco que o usuário escolheu (re)apareceu e o atual é auto → volta pra ele (desmonte transitório).
        if destWasAutoSelected, let uuid = preferredDestUUID, !uuid.isEmpty,
           let v = dests.first(where: { $0.volumeUUID == uuid }) {
            destinationURL = v.url; destWasAutoSelected = false
        }
        if destinationURL == nil {
            // prefere o disco escolhido pelo usuário se estiver montado; senão o maior (e marca como auto).
            if let uuid = preferredDestUUID, !uuid.isEmpty, let v = dests.first(where: { $0.volumeUUID == uuid }) {
                destinationURL = v.url; destWasAutoSelected = false
            } else {
                destinationURL = dests.first?.url; destWasAutoSelected = (destinationURL != nil)
            }
        }
        if let b = backupURL, b == destinationURL || samePhysicalDisk(b, destinationURL) { backupURL = nil }
        refreshCardPreview()
    }

    /// Escolha EXPLÍCITA de destino pelo usuário (seletor): marca o disco preferido (sticky a desmonte),
    /// reconcilia (limpa backup fantasma se virou o mesmo disco) e persiste.
    func setUserDestination(_ url: URL?) {
        destinationURL = url
        preferredDestUUID = volume(url)?.volumeUUID
        destWasAutoSelected = false
        reconcileVolumes()
        saveDiskSelection()
        probeInternalPermission(url)
    }

    /// Atalho interno protegido (Mesa/Documentos) dispara o prompt do macOS no 1º acesso. Faz um acesso
    /// leve em background pra (a) provocar o prompt cedo e (b) detectar negação e avisar antes de copiar.
    private func probeInternalPermission(_ url: URL?) {
        guard let url, isInternalDestination(url) else { internalPermissionDenied = false; return }
        Task.detached { [weak self] in
            let ok = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            // só atualiza o aviso se o destino ainda for ESTE (evita um probe antigo sobrescrever o atual).
            await MainActor.run { if self?.destinationURL == url { self?.internalPermissionDenied = !ok } }
        }
    }

    /// Recarrega a lista (fábrica + salvos) e, opcionalmente, seleciona um preset.
    /// Chamado no início e depois que o editor salva/exclui um preset.
    func reloadPresets(selecting id: String? = nil, preserveContext: Bool = false) {
        presets = [.factoryDefault] + ((try? presetStore.list()) ?? [])
        if let id, id != selectedPresetId, presets.contains(where: { $0.id == id }) {
            // o editor mudou a seleção: preserveContext=true não pode apagar a Pasta que o voluntário
            // já digitou. A troca dispara presetSelectionChanged (onChange) — o id faz ele pular o reset.
            if preserveContext { pendingProgrammaticPresetId = id }
            selectedPresetId = id
        }
        if eventName.trimmingCharacters(in: .whitespaces).isEmpty { eventName = activePreset.evento }
        let validKeys = Set(activePreset.sessionFields.map { $0.key })   // poda campos órfãos
        sessionValues = sessionValues.filter { validKeys.contains($0.key) }
        refreshCardPreview()
    }

    /// Chamado pelo onChange de selectedPresetId. Troca MANUAL do Picker reseta a Pasta/campos pro
    /// padrão do preset; troca programática (restore/editor) preserva o que foi digitado.
    func presetSelectionChanged() {
        // troca programática (restore/editor marcou este id) → preserva o contexto digitado, só atualiza
        // a prévia. Comparar por VALOR, em vez de um flag de uso único, evita o vazamento quando o
        // onChange não dispara no startup — assim a próxima troca MANUAL não é engolida.
        if selectedPresetId == pendingProgrammaticPresetId {
            pendingProgrammaticPresetId = nil
            refreshCardPreview()
            return
        }
        pendingProgrammaticPresetId = nil   // troca MANUAL invalida um programático que tenha vazado
        eventName = activePreset.evento
        sessionValues = [:]
        refreshCardPreview()
        savePresetSelection()   // troca MANUAL de preset (não restauração) → lembra o preset
    }

    /// Calcula a prévia (quantas fotos/vídeos, tamanho) do cartão ativo, em background. NÃO muta
    /// destino/backup (isso é do reconcileVolumes) — assim não re-dispara a si mesmo via onChange.
    func refreshCardPreview() {
        previewGeneration &+= 1
        let gen = previewGeneration
        (destinationFreeBytes, destinationTotalBytes) = freeAndTotal(of: destinationURL)
        (backupFreeBytes, backupTotalBytes) = freeAndTotal(of: backupURL)
        let dests = offloadDestinations
        let cardURL = detectedCard?.url
        // trocou de fonte → limpa os stats da fonte anterior (mostra "calculando…").
        if cardURL != previewedCardURL { cardPreview = nil }
        previewedCardURL = cardURL
        // trocou destino/backup → recalcula o ESPAÇO na hora (rápido) com o total já conhecido, pra
        // canStart/avisos não usarem shortfall obsoleto enquanto a nova prévia não chega.
        if dests != previewedDestinations, var pv = cardPreview {
            let checker = SpaceChecker(provider: VolumeFreeSpace())
            pv.shortfalls = dests.compactMap { dest -> SpaceChecker.Shortfall? in
                let margin = isInternalDestination(dest) ? CopyService.internalReserveBytes : 100 * 1024 * 1024
                return (try? checker.check(requiredBytesPerDestination: pv.totalBytes,
                                           destinations: [dest], marginBytes: margin))?.first
            }
            cardPreview = pv
        }
        previewedDestinations = dests
        guard let card = cardURL, !dests.isEmpty else { cardPreview = nil; return }
        let preset = activePreset
        let media = preset.media.mode == .locked ? preset.media.lockedTo : mediaChoice
        let since = capturedSince
        let internalDests = Set(dests.filter { isInternalDestination($0) })
        Task.detached { [weak self] in
            let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())
            let pv = try? service.preview(cardRoot: card, chosenMedia: media, destinations: dests,
                                          capturedSince: since, internalDestinations: internalDests)
            await MainActor.run {
                guard let self, self.previewGeneration == gen else { return }   // ignora resultado obsoleto
                self.cardPreview = pv   // a trava compara o NÚMERO confirmado, então não precisa resetar aqui
            }
        }
    }

    func startOffload() {
        let destinations = offloadDestinations
        guard let card = detectedCard?.url, !destinations.isEmpty else { return }
        var preset = activePreset
        preset.evento = effectiveEvento                 // pasta-mãe do que o usuário definiu
        let media = preset.media.mode == .locked ? preset.media.lockedTo : mediaChoice
        let camera = self.camera
        var session = sessionValues
        session["camera"] = camera
        cardEjected = false; ejectError = nil
        offloadStartedAt = Date(); lastElapsed = nil
        let cardName = detectedCard?.name ?? card.lastPathComponent   // capturado agora (some ao ejetar)
        let since = capturedSince                                     // filtro "só hoje", se ligado
        let internalDests = Set(destinations.filter { isInternalDestination($0) })   // reserva de 5GB no interno
        isCancelling = false                                         // run novo: limpa feedback de Parar anterior
        state = .running(OffloadProgress(phase: .scanning, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))

        offloadTask = Task.detached { [weak self] in
            let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())
            do {
                let outcome = try service.run(
                    cardRoot: card, chosenMedia: media, destinations: destinations, camera: camera,
                    sessionValues: session,
                    capturedSince: since,
                    internalDestinations: internalDests,
                    isCancelled: { Task.isCancelled },   // botão Parar cancela este Task → checado entre arquivos
                    onProgress: { p in
                        Task { @MainActor in
                            guard let self, case .running(let cur) = self.state else { return }
                            // ignora progresso fora de ordem (Tasks não-estruturadas não preservam
                            // ordem de entrega) — senão a barra por bytes recuaria/piscaria e passaria
                            // sensação de travamento, levando o leigo a abortar um offload saudável.
                            if p.phase.order > cur.phase.order || (p.phase == cur.phase && p.bytesDone >= cur.bytesDone) {
                                self.state = .running(p)
                            }
                        }
                    }
                )
                await MainActor.run {
                    guard let self else { return }
                    if let s = self.offloadStartedAt { self.lastElapsed = Date().timeIntervalSince(s) }
                    self.state = .finished(outcome)
                    // decisão ÚNICA (mesma da UI): só ejeta quando é seguro formatar. Cartão vazio /
                    // filtro errado não pode dar luz verde + ejeção (enganaria o operador).
                    if outcome.canSafelyFormatCard { self.ejectCard(at: card) }
                    self.notifyFinished(outcome, cardName: cardName)
                }
            } catch let error as OffloadError {
                // espaço (pré-voo) e permissão negada (TCC, na criação da pasta) acontecem ANTES de copiar
                // → cartão intocado. Os demais (ex.: caminho inválido) também lançam antes de escrever, mas
                // avisamos por garantia (lado seguro).
                let isPermission: Bool = { if case .permissionDenied = error { return true } else { return false } }()
                let cardSafe: Bool = isPermission || { if case .notEnoughSpace = error { return true } else { return false } }()
                let msg = error.errorDescription ?? "\(error)"
                let isCancel: Bool = { if case .cancelled = error { return true } else { return false } }()
                await MainActor.run {
                    if isPermission { self?.internalPermissionDenied = true }   // reacende o aviso pra liberar acesso
                    self?.state = .failed(msg, cardUncertain: !cardSafe)
                    // cancelamento é do próprio usuário (ele está ali) → não dispara notificação de "falha".
                    if !isCancel { self?.notifyFailed(uncertain: !cardSafe, cardName: cardName) }
                }
            } catch let error as NamingError {
                // erro de template (mesmo p/ todo arquivo) lança ANTES de copiar → cartão intocado.
                let msg = error.errorDescription ?? "\(error)"
                await MainActor.run { self?.state = .failed(msg, cardUncertain: false); self?.notifyFailed(uncertain: false, cardName: cardName) }
            } catch {
                // falha durante a cópia (disco removido, I/O, etc.) → estado do destino incerto.
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.state = .failed(msg, cardUncertain: true); self?.notifyFailed(uncertain: true, cardName: cardName) }
            }
        }
    }

    /// Aviso do sistema ao terminar — pra quem saiu de perto durante a cópia (vários minutos).
    func notifyFinished(_ outcome: OffloadOutcome, cardName: String) {
        if !outcome.failures.isEmpty {
            Notifier.notify(title: "Atenção: falha no backup",
                            body: "NÃO formate o cartão \(cardName). \(outcome.failures.count) arquivo(s) não passaram na conferência.")
        } else if outcome.canSafelyFormatCard {
            Notifier.notify(title: "Backup concluído",
                            body: "Cartão \(cardName) verificado. Pode formatar com segurança.")
        }
        // nada salvo (cartão vazio / filtro errado) → sem notificação
    }

    func notifyFailed(uncertain: Bool, cardName: String) {
        if uncertain {
            Notifier.notify(title: "Backup interrompido",
                            body: "NÃO formate o cartão \(cardName). A mídia não foi totalmente verificada — tente de novo.")
        } else {
            Notifier.notify(title: "Backup não realizado",
                            body: "O cartão \(cardName) está intacto. Veja o aviso no Cardflow.")
        }
    }

    /// Abre o relatório legível (manifesto .txt) da cópia — lista o que foi salvo e conferido,
    /// pra dar confiança e servir de prova pra um responsável. Reusa o que o motor já gravou.
    func openReport(_ outcome: OffloadOutcome) {
        guard let jsonPath = outcome.manifestPaths.first else { return }
        let txt = URL(fileURLWithPath: jsonPath).deletingPathExtension().appendingPathExtension("txt")
        let target = FileManager.default.fileExists(atPath: txt.path) ? txt : URL(fileURLWithPath: jsonPath)
        NSWorkspace.shared.open(target)
    }

    /// Abre a pasta do evento no destino — de onde a confiança do leigo vem: ver os arquivos com os
    /// próprios olhos antes de formatar. Usa o manifesto (já tem o caminho) ou o destino principal.
    func revealOffloadInFinder(_ outcome: OffloadOutcome) {
        let target: URL
        if let first = outcome.manifestPaths.first {
            // .../<dest>/<evento>/.cardflow/manifest-x.json → sobe 2 níveis = pasta do evento
            target = URL(fileURLWithPath: first).deletingLastPathComponent().deletingLastPathComponent()
        } else if let d = destinationURL {
            target = d
        } else { return }
        NSWorkspace.shared.open(target)
    }

    /// Ejeta o cartão (volume) ao terminar com sucesso. Se o disco estiver ocupado, não trava: avisa.
    func ejectCard(at url: URL) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            cardEjected = true; ejectError = nil
        } catch {
            cardEjected = false; ejectError = error.localizedDescription
        }
    }

    /// Re-tenta ejetar o cartão (depois de o usuário fechar a janela do Finder que o segurava).
    func retryEject() {
        if let u = detectedCard?.url { ejectCard(at: u) }
    }

    /// Histórico de cópias do destino atual (lê os manifestos já gravados). Vazio se não há destino.
    func loadHistory() -> [Manifest] {
        guard let dest = destinationURL else { return [] }
        return ManifestStore().loadAllInDestination(dest)
    }

    /// Para a transferência em andamento. O cancelamento checa entre blocos (interrompe no meio de
    /// um arquivo grande): o motor drena a verificação, limpa o parcial e registra um manifesto parcial.
    func cancelOffload() {
        guard isBusy else { return }
        isCancelling = true   // feedback imediato (o encerramento pode levar até o fim do bloco atual)
        offloadTask?.cancel()
    }

    func reset() {
        offloadTask?.cancel(); offloadTask = nil   // não deixa um offload órfão rodando após reset
        isCancelling = false
        state = .idle
        cardEjected = false; ejectError = nil
        offloadStartedAt = nil; lastElapsed = nil
        backupURL = nil; backupFreeBytes = nil; backupTotalBytes = nil
    }
}
