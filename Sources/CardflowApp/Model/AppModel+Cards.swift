import Foundation
import OffloadKit

/// Ciclo de vida de cada cartão: aparece → é lido UMA vez → prévia recalculada sobre a lista em memória
/// (trocar mídia, destino ou modelo não relê o cartão) → sai do Mac.
extension AppModel {
    /// Sincroniza `cards` com as fontes montadas. O mesmo caminho com outro volume (outro "Untitled") é
    /// outro cartão: o anterior sai e o novo é lido do zero.
    func syncCards(with srcs: [ExternalVolume]) {
        var next: [CardSession] = []
        for v in srcs {
            if let existing = cards.first(where: { $0.id == v.id && Self.sameMedium($0.volume, v) }) {
                next.append(existing)
            } else if let owner = cards.first(where: { Self.ownsRemount($0, v) }), !next.contains(where: { $0 === owner }) {
                // o volume que volta da formatação (mesmo disco físico) é o MESMO cartão, não um novo e vazio
                next.append(owner)
            } else {
                let c = CardSession(volume: v, mediaChoice: defaultMediaChoice)
                c.defaultCamera = CameraMetadata.defaultName(avoiding: Set((cards + next).map(\.defaultCamera)))
                c.camera = c.defaultCamera
                next.append(c)
                startScan(c)
                startWatching(c)
            }
        }
        // formatando: o cartão some do Mac por uns segundos (desmonta e remonta) sem ter "saído"
        for c in cards where Self.isFormatInFlight(c) && !next.contains(where: { $0 === c }) { next.append(c) }
        let leaving = cards.filter { old in !next.contains { $0 === old } }
        let arrived = next.filter { new in !cards.contains { $0 === new } }
        cards = next
        for c in leaving { cardDidLeave(c) }
        // seleção: sem nada escolhido, o primeiro cartão; cartão novo ganha a vez se o que está à vista
        // não está ocupado (copiando, na fila, formatando).
        let current: CardSession? = { if case .card(let id)? = selection { return card(id: id) }; return nil }()
        if !selectionByUser {
            if let first = cards.first { selection = .card(first.id) }
        } else if let new = arrived.first, current == nil || current?.isDone == true {
            selection = .card(new.id)
        } else if selection == nil || isCardSelectionGone, let first = cards.first {
            selection = .card(first.id)
        }
    }

    private var isCardSelectionGone: Bool {
        if case .card(let id)? = selection { return card(id: id) == nil }
        return false
    }

    /// Formatação em andamento, ou recém-terminada esperando o volume voltar.
    private static func isFormatInFlight(_ c: CardSession) -> Bool {
        switch c.formatState {
        case .checking, .confirming, .formatting: return true
        case .done: return !c.ejected && (c.formattedAt.map { Date().timeIntervalSince($0) < 30 } ?? false)
        default: return false
        }
    }

    /// Este cartão é dono do volume `v`? Durante e depois da formatação (até ejetar), o volume novo que
    /// aparece no mesmo disco físico é ele mesmo.
    private static func ownsRemount(_ c: CardSession, _ v: ExternalVolume) -> Bool {
        guard let disk = c.volume.physicalDeviceID, disk == v.physicalDeviceID else { return false }
        switch c.formatState {
        case .checking, .confirming, .formatting: return true
        case .done: return !c.ejected
        default: return false
        }
    }

    private static func sameMedium(_ a: ExternalVolume, _ b: ExternalVolume) -> Bool {
        a.volumeUUID == b.volumeUUID && a.totalBytes == b.totalBytes
    }

    /// O cartão saiu do Mac. Sai da fila sem erro. Se tinha terminado bem, deixa um resumo (CompletedCard)
    /// que fica à vista no lugar dele: quem volta encontra "pronto, pode tirar" e não uma tela vazia.
    func cardDidLeave(_ card: CardSession) {
        card.scanTask?.cancel()
        card.watcher?.stop(); card.watcher = nil
        queue.remove(card.id)
        let wasSelected: Bool = {
            switch selection {
            case .card(let id)?: return id == card.id
            case nil: return true   // sem escolha, o detalhe mostrava este cartão
            default: return false
            }
        }()
        reloadHistory()   // em segundo plano: Recentes ganha a cópia assim que a lista chega
        if let done = completion(for: card) {
            completed.insert(done, at: 0)
            if completed.count > 6 { completed.removeLast(completed.count - 6) }
            if wasSelected {
                selection = .completed(done.id)
                selectionByUser = true   // fica no resumo; cartão novo que chegar toma a vez
            }
            return
        }
        guard wasSelected else { return }
        selection = cards.first.map { .card($0.id) }
    }

    private func completion(for card: CardSession) -> CompletedCard? {
        let ctx = card.offloadContext
        let dests = ctx?.destinations ?? offloadDestinations
        var paths: [String] = []
        if case .finished = card.phase {} else if card.isAlreadyCopied, let c = ctx ?? currentOffloadContext(for: card) {
            paths = manifestPaths(of: card, ctx: c)
        }
        return CompletedCard.make(from: card, destinations: dests, manifestPaths: paths)
    }

    /// Fecha o resumo de um cartão concluído.
    func dismissCompleted(_ id: String) {
        completed.removeAll { $0.id == id }
        if case .completed(let sel)? = selection, sel == id {
            selection = cards.first.map { .card($0.id) }
        }
    }

    static func offloadId(fromManifestPaths paths: [String]) -> String? {
        guard let p = paths.first, let data = FileManager.default.contents(atPath: p) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Manifest.self, from: data))?.offloadId
    }

    // MARK: Mudanças no cartão conectado

    /// Relê o cartão quando algo muda nele (FSEvents), pra a prévia nunca ficar velha.
    func startWatching(_ card: CardSession) {
        card.watcher = FolderWatcher(path: card.volume.url.path) { [weak self, weak card] in
            guard let self, let card else { return }
            self.rescan(card)
        }
    }

    /// Dá pra reler agora? Não durante a leitura, a fila, a cópia ou a formatação (que troca o volume).
    func canRescan(_ card: CardSession) -> Bool {
        guard card.scanTask == nil, !card.isBusy, card.scanned != nil else { return false }
        switch card.formatState {
        case .checking, .confirming, .formatting, .done: return false
        default: break
        }
        switch card.phase {
        case .ready, .finished, .failed: return true
        default: return false
        }
    }

    func rescan(_ card: CardSession) {
        guard canRescan(card) else { return }
        let root = card.volume.url
        card.scanTask = Task.detached { [weak self] in
            let files = try? CardScanner(classifier: FileClassifier()).scan(cardRoot: root)
            await MainActor.run {
                card.scanTask = nil
                guard let self, let files, self.cards.contains(where: { $0 === card }) else { return }
                _ = self.applyRescan(card, files: files)
            }
        }
    }

    /// Aplica a releitura. Mudou alguma coisa: atualiza a lista e a prévia; um cartão que já tinha terminado
    /// e ganhou ou perdeu arquivos volta a "pronto pra copiar" (o resultado anterior não vale mais pra ele).
    @discardableResult
    func applyRescan(_ card: CardSession, files: [MediaFile]) -> Bool {
        func key(_ f: [MediaFile]) -> [String: Int64] { Dictionary(f.map { ($0.relPath, $0.size) }, uniquingKeysWith: { a, _ in a }) }
        guard key(files) != key(card.scanned ?? []) else { return false }
        card.scanned = files
        switch card.phase {
        case .finished, .failed:
            card.phase = .ready
            card.finishedAt = nil; card.startedAt = nil; card.lastElapsed = nil
            card.formatState = .idle
        default: break
        }
        autoDetectCamera(card)
        recomputePreview(card)
        return true
    }

    /// Ao voltar pro app: relê os cartões parados e recalcula as prévias (espaço livre dos discos muda por fora).
    func refreshOnActivate() {
        for c in cards {
            recomputePreview(c)
            if canRescan(c) { rescan(c) }
        }
    }

    func startScan(_ card: CardSession) {
        card.phase = .scanning
        let root = card.volume.url
        card.scanTask = Task.detached { [weak self] in
            let files = try? CardScanner(classifier: FileClassifier()).scan(cardRoot: root)
            await self?.scanFinished(card, files: files)
        }
    }

    private func scanFinished(_ card: CardSession, files: [MediaFile]?) {
        guard cards.contains(where: { $0 === card }) else { return }
        card.scanned = files ?? []
        card.scanTask = nil
        if card.phase == .scanning { card.phase = .ready }
        autoDetectCamera(card)
        recomputePreview(card)
    }

    /// Mídia que a cópia deste cartão usa (o modelo pode travar).
    func effectiveMedia(_ card: CardSession) -> Preset.Media.Kind {
        let p = workingPreset
        return p.media.mode == .locked ? p.media.lockedTo : card.mediaChoice
    }

    /// Recalcula a prévia sobre a lista já lida, em segundo plano. Resultado antigo é descartado.
    func recomputePreview(_ card: CardSession) {
        guard let scanned = card.scanned else { return }
        switch card.phase { case .running, .queued: return; default: break }
        card.previewGeneration &+= 1
        let gen = card.previewGeneration
        let dests = offloadDestinations
        let preset = previewPreset
        let media = effectiveMedia(card)
        let interval = card.capturedIn
        let internalDests = Set(dests.filter { isInternalDestination($0) })
        let root = card.volume.url
        let camera = card.camera, cardName = card.volume.name
        let cameras = card.camerasByGroup, excluded = card.excludedGroups
        var session = sessionValues
        session["camera"] = camera
        Task.detached {
            let locale = AppLocale.effective
            let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace(), locale: locale)
            let pv = try? service.preview(scanned: scanned, cardRoot: root, chosenMedia: media, destinations: dests,
                                          capturedIn: interval, excludedGroups: excluded, internalDestinations: internalDests)
            let tree = OrganizationTree.build(files: service.selectedFiles(scanned, chosenMedia: media, capturedIn: interval,
                                                                           excludedGroups: excluded),
                                              preset: preset, camera: camera, cameras: cameras, cardName: cardName, sessionValues: session,
                                              lote: pv?.lote?.numero, locale: locale)
            await MainActor.run {
                guard card.previewGeneration == gen else { return }
                card.preview = pv
                card.tree = tree
            }
        }
    }

    func recomputeAllPreviews() {
        for c in cards {
            autoDetectCamera(c)
            recomputePreview(c)
        }
    }

    func setMediaChoice(_ kind: Preset.Media.Kind, for card: CardSession) {
        card.mediaChoice = kind
        defaultMediaChoice = kind
        savePresetSelection()
        recomputePreview(card)
    }

    func setCaptureDateFilter(_ filter: CaptureDateFilter, for card: CardSession) {
        card.captureDateFilter = filter
        recomputePreview(card)
    }

    /// Preenche a câmera pelo metadado (EXIF/QuickTime) do 1º arquivo legível, uma vez por cartão e só
    /// quando o modelo usa {camera}. Não atropela ajuste manual (não roda de novo no mesmo cartão).
    func autoDetectCamera(_ card: CardSession) {
        // sempre, mesmo sem a peça Câmera no modelo: o exemplo da opção Câmera já mostra a câmera real
        guard !card.cameraDetected, let scanned = card.scanned else { return }
        card.cameraDetected = true
        Task {
            // uma leitura por pasta do cartão (cada câmera grava na sua); nome curto como quem filma fala
            // ("FX30", não "SONY ILME-FX30"); sem detecção fica CAM A/B…
            let byGroup = await CameraGroups.detect(in: scanned).mapValues(CameraMetadata.shortName)
            guard !byGroup.isEmpty else { return }
            card.detectedByGroup = byGroup
            // câmera "do cartão" (uma câmera só, ou a maior quando tem várias)
            if let main = card.cameraEntries.first(where: { $0.detected != nil })?.detected {
                card.detectedCamera = main
                if !card.cameraEdited { card.camera = main }
            }
            recomputePreview(card)
        }
    }
}
