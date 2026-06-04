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
    var state: OffloadState = .idle
    var cardPreview: OffloadPreview?   // prévia do cartão detectado (contagem/tamanho)
    var eventName: String = ""                   // pasta-mãe (sobrescreve o evento do preset nesta sessão)
    var sessionValues: [String: String] = [:]    // valores de campos personalizados do preset
    var destinationFreeBytes: Int64?
    var destinationTotalBytes: Int64?
    var backupFreeBytes: Int64?
    var backupTotalBytes: Int64?
    var cardEjected = false            // cartão foi ejetado automaticamente ao terminar com sucesso
    var ejectError: String?           // ejeção falhou (disco ocupado) → avisa pra ejetar à mão
    var availableUpdate: UpdateInfo?  // versão mais nova no GitHub (checagem discreta no start)
    var forcedSources: Set<String> = []        // discos que o usuário marcou como fonte (override)
    var forcedDestinations: Set<String> = []   // discos que o usuário marcou como destino (override)
    var selectedCardURL: URL?                  // qual fonte está ativa quando há várias
    private var previewGeneration = 0   // descarta prévias de cartão obsoletas (last-writer-wins)
    private var previewedCardURL: URL?  // a fonte que a prévia atual representa (pra limpar ao trocar)
    private var previewedDestinations: [URL] = []   // destinos da prévia atual (pra recalcular espaço ao trocar)
    private var suppressPresetResetOnce = false     // o editor mudou a seleção → não reseta a Pasta dessa vez

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
    var destinations: [ExternalVolume] {
        watcher.volumes.filter { !isSource($0) }.sorted { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }
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
        // sem prévia ainda (checagem de espaço em andamento) → não habilita ainda (evita iniciar às cegas)
        guard let sf = cardPreview?.shortfalls else { return false }
        return sf.isEmpty   // não deixa iniciar com disco sem espaço
    }
    /// Algum destino (principal/backup) não cabe? Usa a checagem do motor (com margem real).
    func hasShortfall(_ url: URL?) -> Bool {
        guard let url, let sf = cardPreview?.shortfalls else { return false }
        return sf.contains { $0.destination == url }
    }
    var principalTooSmall: Bool { hasShortfall(destinationURL) }
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
        return watcher.volumes.first { $0.url == url }
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
              let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        else { return (nil, nil) }
        return (v.volumeAvailableCapacityForImportantUsage, v.volumeTotalCapacity.map { Int64($0) })
    }

    func start() {
        watcher.start()
        reloadPresets()
        restoreSession()    // restaura o que foi lembrado (destino só se o disco estiver plugado)
        reconcileVolumes()  // valida + auto-maior só se a restauração não setou destino
        checkForUpdates()   // discreto: pergunta ao GitHub se há versão nova (falha silenciosa)
    }

    /// Checagem de atualização: a única chamada de rede do app. Não envia nada; só lê a versão
    /// da última release no GitHub. Falhou (offline, repo privado)? Não mostra nada.
    func checkForUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? OffloadKit.version
        Task { [weak self] in
            let info = await UpdateChecker.checkForUpdate(current: current)
            await MainActor.run { self?.availableUpdate = info }
        }
    }

    /// Restaura preset/destino/backup/mídia da última sessão (uma vez, no start, após presets+volumes).
    func restoreSession() {
        guard let s = sessionStore.load() else { return }
        // só seta o flag se a atribuição REALMENTE muda o id (senão o onChange não dispara, o flag não é
        // consumido e vazaria pra próxima troca manual — bug do restore == factory-default).
        if let pid = s.activePresetId, pid != selectedPresetId, presets.contains(where: { $0.id == pid }) {
            suppressPresetResetOnce = true       // o onChange vai disparar; não apaga o contexto restaurado
            selectedPresetId = pid
        }
        if let kind = Preset.Media.Kind(rawValue: s.lastMediaChoice) { mediaChoice = kind }
        if !s.sessionValues.isEmpty { sessionValues = s.sessionValues }
        eventName = activePreset.evento   // Pasta = evento do preset RESTAURADO (não fica preso no default)
        preferredDestUUID = s.destinationBindings["principal"]?.volumeUUID   // sticky mesmo se não plugado agora
        if let d = s.destinationBindings["principal"]?.resolve(in: watcher.volumes) { destinationURL = d }
        if let b = s.destinationBindings["backup"]?.resolve(in: watcher.volumes) { backupURL = b }
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
        guard let url, let v = watcher.volumes.first(where: { $0.url == url }) else { return nil }
        let uuid = (v.volumeUUID?.isEmpty == false) ? v.volumeUUID : nil   // UUID vazio = ausente (evita falso-match)
        return DiskBinding(volumeUUID: uuid, lastKnownPath: v.url.path)
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
    }

    /// Recarrega a lista (fábrica + salvos) e, opcionalmente, seleciona um preset.
    /// Chamado no início e depois que o editor salva/exclui um preset.
    func reloadPresets(selecting id: String? = nil, preserveContext: Bool = false) {
        presets = [.factoryDefault] + ((try? presetStore.list()) ?? [])
        if let id, id != selectedPresetId, presets.contains(where: { $0.id == id }) {
            // o editor mudou a seleção: preserveContext=true não pode apagar a Pasta que o voluntário
            // já digitou. A troca dispara presetSelectionChanged (onChange) — o flag faz ele pular o reset.
            if preserveContext { suppressPresetResetOnce = true }
            selectedPresetId = id
        }
        if eventName.trimmingCharacters(in: .whitespaces).isEmpty { eventName = activePreset.evento }
        let validKeys = Set(activePreset.sessionFields.map { $0.key })   // poda campos órfãos
        sessionValues = sessionValues.filter { validKeys.contains($0.key) }
        refreshCardPreview()
    }

    /// Chamado pelo onChange de selectedPresetId. Troca MANUAL do Picker reseta a Pasta/campos pro
    /// padrão do preset; troca vinda do editor (suppressPresetResetOnce) preserva o que foi digitado.
    func presetSelectionChanged() {
        if suppressPresetResetOnce { suppressPresetResetOnce = false; refreshCardPreview(); return }
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
            pv.shortfalls = (try? SpaceChecker(provider: VolumeFreeSpace())
                .check(requiredBytesPerDestination: pv.totalBytes, destinations: dests, marginBytes: 100 * 1024 * 1024)) ?? []
            cardPreview = pv
        }
        previewedDestinations = dests
        guard let card = cardURL, !dests.isEmpty else { cardPreview = nil; return }
        let preset = activePreset
        let media = preset.media.mode == .locked ? preset.media.lockedTo : mediaChoice
        Task.detached { [weak self] in
            let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())
            let pv = try? service.preview(cardRoot: card, chosenMedia: media, destinations: dests)
            await MainActor.run {
                guard let self, self.previewGeneration == gen else { return }   // ignora resultado obsoleto
                self.cardPreview = pv
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
        state = .running(OffloadProgress(phase: .scanning, filesDone: 0, filesTotal: 0, bytesDone: 0, bytesTotal: 0))

        Task.detached { [weak self] in
            let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())
            do {
                let outcome = try service.run(
                    cardRoot: card, chosenMedia: media, destinations: destinations, camera: camera,
                    sessionValues: session,
                    onProgress: { p in
                        Task { @MainActor in
                            guard let self else { return }
                            // nunca deixa um progresso atrasado sobrescrever o estado terminal
                            if case .running = self.state { self.state = .running(p) }
                        }
                    }
                )
                await MainActor.run {
                    guard let self else { return }
                    self.state = .finished(outcome)
                    // só ejeta quando ALGO foi de fato salvo (copiado agora ou já presente): um cartão
                    // vazio / filtro errado não pode dar luz verde + ejeção (engana o operador).
                    let salvou = outcome.verifiedCount > 0 || !outcome.skipped.isEmpty
                    if outcome.failures.isEmpty && salvou { self.ejectCard(at: card) }
                }
            } catch let error as OffloadError {
                // pré-voo (espaço) acontece ANTES de copiar → cartão intocado. Os demais (ex.: caminho
                // inválido) também lançam antes de escrever, mas avisamos por garantia (lado seguro).
                let uncertain: Bool = { if case .notEnoughSpace = error { return false } else { return true } }()
                let msg = error.errorDescription ?? "\(error)"
                await MainActor.run { self?.state = .failed(msg, cardUncertain: uncertain) }
            } catch let error as NamingError {
                // erro de template (mesmo p/ todo arquivo) lança ANTES de copiar → cartão intocado.
                let msg = error.errorDescription ?? "\(error)"
                await MainActor.run { self?.state = .failed(msg, cardUncertain: false) }
            } catch {
                // falha durante a cópia (disco removido, I/O, etc.) → estado do destino incerto.
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self?.state = .failed(msg, cardUncertain: true) }
            }
        }
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

    func reset() {
        state = .idle
        cardEjected = false; ejectError = nil
        backupURL = nil; backupFreeBytes = nil; backupTotalBytes = nil
    }
}
