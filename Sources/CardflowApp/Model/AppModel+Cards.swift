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
            } else {
                let c = CardSession(volume: v, mediaChoice: defaultMediaChoice)
                c.defaultCamera = CameraMetadata.defaultName(avoiding: Set((cards + next).map(\.defaultCamera)))
                c.camera = c.defaultCamera
                next.append(c)
                startScan(c)
            }
        }
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

    private static func sameMedium(_ a: ExternalVolume, _ b: ExternalVolume) -> Bool {
        a.volumeUUID == b.volumeUUID && a.totalBytes == b.totalBytes
    }

    /// O cartão saiu do Mac. Sai da fila sem erro; se estava selecionado e já tinha resultado, a seleção
    /// passa pro item dele em Recentes (o resultado continua à vista, sem "Formatar" apontando pro nada).
    func cardDidLeave(_ card: CardSession) {
        card.scanTask?.cancel()
        queue.remove(card.id)
        let wasSelected: Bool = { if case .card(let id)? = selection { return id == card.id }; return false }()
        guard wasSelected else { return }
        reloadHistory()   // em segundo plano: o detalhe de Recentes aparece assim que a lista chega
        if case .finished(let o) = card.phase, let id = Self.offloadId(fromManifestPaths: o.manifestPaths) {
            selection = .recent(id)
            selectionByUser = true   // fica no resultado; não volta sozinha pro primeiro cartão
        } else {
            selection = cards.first.map { .card($0.id) }
        }
    }

    static func offloadId(fromManifestPaths paths: [String]) -> String? {
        guard let p = paths.first, let data = FileManager.default.contents(atPath: p) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Manifest.self, from: data))?.offloadId
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
