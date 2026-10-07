import Foundation
import OffloadKit
import CardFormatKit

/// Fase da cópia de UM cartão. A formatação tem estado próprio (`CardSession.formatState`).
enum CardPhase: Equatable {
    case scanning                    // lendo o cartão (lista de arquivos)
    case ready                       // prévia pronta (ou calculando, com `preview == nil`)
    case queued                      // esperando a vez na fila
    case running(OffloadProgress)
    case finished(OffloadOutcome)
    case failed(String, cardUncertain: Bool)   // cardUncertain: falhou DURANTE a cópia → não formatar
}

/// Estado e regras de um cartão conectado. Cada cartão tem a sua prévia, a sua escolha de mídia, a sua
/// câmera e a sua formatação; o que é do projeto (modelo, destinos, nome) fica no `AppModel`.
@MainActor @Observable
final class CardSession: Identifiable {
    nonisolated let volume: ExternalVolume
    nonisolated var id: String { volume.id }

    var phase: CardPhase = .scanning
    /// Lista do cartão, lida uma vez por montagem. A prévia é recalculada sobre ela.
    var scanned: [MediaFile]?
    var preview: OffloadPreview?
    /// Prévia "Vai ficar assim", calculada junto com a prévia.
    var tree: [TreeNode] = []
    var mediaChoice: Preset.Media.Kind
    var camera: String = "CAM A"
    var cameraDetected = false
    /// Câmera lida do metadado dos arquivos, já no nome curto ("FX30", "A7S III").
    var detectedCamera: String?
    /// A pessoa escolheu ou digitou o nome: a detecção não troca mais.
    var cameraEdited = false
    /// Nome de câmera de reserva deste cartão (CAM A, CAM B…), pra arquivo sem câmera identificada.
    var defaultCamera = "CAM A"
    /// Câmera lida em cada grupo de origem (pasta do cartão), no nome curto.
    var detectedByGroup: [String: String] = [:]
    /// Cartão com várias câmeras: o nome escolhido de cada uma e as que ficam de fora.
    var cameraNames: [String: String] = [:]
    var excludedCameras: Set<String> = []
    var captureDateFilter: AppModel.CaptureDateFilter = .all
    var acknowledgedIncompleteLote: Int?
    var formatState: AppModel.FormatUIState = .idle
    var confirmingAutomatically = false
    var offloadContext: AppModel.OffloadContext?
    var startedAt: Date?
    var lastElapsed: TimeInterval?
    var ejected = false
    /// Horário de cada etapa, pro resumo de conclusão (CompletedCard).
    var finishedAt: Date?
    var formattedAt: Date?
    var ejectedAt: Date?
    var ejectError: String?
    var isCancelling = false
    /// Cópia/fila ou formatação em andamento: o cartão não pode ser trocado de papel nem ejetado.
    var isBusy: Bool {
        switch phase {
        case .running, .queued: return true
        default: if case .formatting = formatState { return true }; return false
        }
    }

    @ObservationIgnored var scanTask: Task<Void, Never>?
    /// Acompanha mudanças no cartão conectado (arquivo novo, apagado) pra reler a lista sozinho.
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var offloadTask: Task<Void, Never>?
    @ObservationIgnored var previewGeneration = 0

    init(volume: ExternalVolume, mediaChoice: Preset.Media.Kind = .both) {
        self.volume = volume
        self.mediaChoice = mediaChoice
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }
    /// Já resolvido: conferido, formatado, ejetado ou tudo já estava no destino. Cartão novo pode tomar a vez.
    var isDone: Bool {
        if ejected { return true }
        if case .done = formatState { return true }
        if case .finished = phase { return true }
        return phase == .ready && isAlreadyCopied
    }

    // MARK: Regras da prévia (vieram do AppModel, mesmos nomes)

    /// Há um lote anterior incompleto detectado e ainda não confirmado pelo usuário? (trava o início).
    var loteLossUnconfirmed: Bool {
        if let inc = preview?.lote?.anteriorIncompleto { return inc != acknowledgedIncompleteLote }
        return false
    }
    /// RETOMADA: parte já está gravada e conferida no destino, e ainda falta copiar.
    var isResume: Bool {
        guard let pv = preview else { return false }
        return pv.alreadyPresent > 0 && pv.alreadyPresent < pv.selectedCount
            && !isComplementalCopy && !isNewLoteWithSaved
    }
    /// Lote NOVO num cartão não formatado: parte já salva (lote anterior CONCLUÍDO) e o resto é novo.
    var isNewLoteWithSaved: Bool {
        guard let pv = preview else { return false }
        return pv.lote?.isNovo == true
            && pv.alreadyPresentFromInterrupted == 0
            && pv.alreadyPresent > 0 && pv.alreadyPresent < pv.selectedCount
    }
    /// Complemento: o usuário mudou a seleção (copiou Foto antes e agora marcou Tudo).
    var isComplementalCopy: Bool {
        guard let pv = preview, mediaChoice == .both else { return false }
        guard pv.alreadyPresent > 0 && pv.alreadyPresent < pv.selectedCount else { return false }
        guard pv.alreadyPresentFromInterrupted == 0 else { return false }
        return alreadyPresentMediaPhrase != nil
    }
    /// Tudo que está selecionado já existe no destino. Não há nada novo a copiar.
    var isAlreadyCopied: Bool {
        guard let pv = preview else { return false }
        return pv.selectedCount > 0 && pv.alreadyPresent >= pv.selectedCount
    }
    /// Cartão sem nada pra copiar (recém-formatado, ou só lixo).
    var isEmpty: Bool {
        guard let pv = preview else { return false }
        return pv.selectedCount == 0 && pv.unrecognized.isEmpty
    }
    var showsRemainingHeadline: Bool { isResume || isComplementalCopy || isNewLoteWithSaved }
    var headlineBytes: Int64 {
        guard let pv = preview else { return 0 }
        return showsRemainingHeadline ? pv.remainingBytes : pv.totalBytes
    }

    var alreadyPresentMediaPhrase: (lower: String, sentenceStart: String, copied: String, ignored: String)? {
        guard let pv = preview else { return nil }
        var labels: [(lower: String, sentenceStart: String, copied: String, ignored: String, count: Int)] = []
        if pv.photos > 0 {
            labels.append((String(localized: "media.photos.lower"), String(localized: "media.photos.sentenceStart"),
                           String(localized: "media.photos.copied"), String(localized: "media.photos.ignored"), pv.photos))
        }
        if pv.videos > 0 {
            labels.append((String(localized: "media.videos.lower"), String(localized: "media.videos.sentenceStart"),
                           String(localized: "media.videos.copied"), String(localized: "media.videos.ignored"), pv.videos))
        }
        if pv.audios > 0 {
            labels.append((String(localized: "media.audios.lower"), String(localized: "media.audios.sentenceStart"),
                           String(localized: "media.audios.copied"), String(localized: "media.audios.ignored"), pv.audios))
        }
        return labels.first { $0.count == pv.alreadyPresent }.map { ($0.lower, $0.sentenceStart, $0.copied, $0.ignored) }
    }

    var alreadyCopiedTitle: String? { isAlreadyCopied ? String(localized: "main.alreadyCopied.title") : nil }
    var alreadyCopiedDetail: String? {
        guard isAlreadyCopied, let pv = preview else { return nil }
        return String(localized: "main.alreadyCopied.detail \(pv.selectedCount)")
    }
    var showsVerifiedResumeOption: Bool { isResume }
    var resumeCardTitle: String? {
        if isComplementalCopy { return String(localized: "main.resume.complementTitle") }
        return isResume ? String(localized: "main.resume.title") : nil
    }
    var resumeCardDetail: String? {
        guard isResume || isComplementalCopy, let pv = preview else { return nil }
        let novos = max(0, pv.selectedCount - pv.alreadyPresent)
        let remaining = Format.humanBytes(pv.remainingBytes)
        if isComplementalCopy, let phrase = alreadyPresentMediaPhrase {
            return String(localized: "main.resume.complementDetail \(String(pv.alreadyPresent)) \(phrase.lower) \(phrase.copied) \(String(novos)) \(remaining)")
        }
        return String(localized: "main.resume.detail \(String(pv.alreadyPresent)) \(String(novos)) \(remaining)")
    }
    var resumeActionHint: String? {
        if isComplementalCopy, let phrase = alreadyPresentMediaPhrase {
            return String(localized: "main.resume.complementHint \(phrase.sentenceStart) \(phrase.copied) \(phrase.ignored)")
        }
        return isResume ? String(localized: "main.resume.hint") : nil
    }

    // MARK: Filtro de data de captura

    var capturedIn: DateInterval? { AppModel.captureDateInterval(for: captureDateFilter) }

    // MARK: Linha da barra lateral

    var statusLine: String {
        if case .formatting = formatState { return String(localized: "card.status.formatting") }
        if case .done = formatState { return String(localized: "card.status.formatted") }
        switch phase {
        case .scanning: return String(localized: "card.status.scanning")
        case .ready:
            guard preview != nil else { return String(localized: "card.status.calculating") }
            if isAlreadyCopied { return String(localized: "card.status.alreadyCopied") }
            if isEmpty { return String(localized: "card.status.empty") }
            return String(localized: "card.status.ready \(Self.bytes(headlineBytes))")
        case .queued: return String(localized: "card.status.queued")
        case .running(let p):
            if p.phase == .verifying { return String(localized: "card.status.verifying") }
            let pct = p.bytesTotal > 0 ? Int(Double(p.bytesDone) / Double(p.bytesTotal) * 100) : 0
            return String(localized: "card.status.copying \(pct)")
        case .finished(let o):
            if o.copiedKeepingCameras { return String(localized: "card.status.verifiedKept") }
            return o.canSafelyFormatCard ? String(localized: "card.status.verified") : String(localized: "card.status.failed")
        case .failed: return String(localized: "card.status.failed")
        }
    }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

// MARK: - Câmeras do cartão

/// Uma câmera encontrada no cartão: as pastas dela e o que tem nelas. `id` é o nome detectado; arquivos
/// sem câmera identificada (áudio, RAW de cinema) ficam juntos numa entrada de id vazio.
struct CameraEntry: Identifiable, Equatable {
    let id: String
    let detected: String?
    var groups: Set<String> = []
    var photos = 0, videos = 0, audios = 0, bytes: Int64 = 0
    var files: Int { photos + videos + audios }
}

extension CardSession {
    /// Câmeras do cartão, a maior primeiro.
    var cameraEntries: [CameraEntry] {
        var byID: [String: CameraEntry] = [:]
        for f in scanned ?? [] where f.preserve || [.photo, .video, .audio].contains(f.type) {
            let g = CameraGroups.key(for: f)
            let det = detectedByGroup[g]
            var e = byID[det ?? ""] ?? CameraEntry(id: det ?? "", detected: det)
            e.groups.insert(g)
            switch f.type {
            case .photo: e.photos += 1
            case .audio: e.audios += 1
            default: e.videos += 1
            }
            e.bytes += f.size
            byID[e.id] = e
        }
        return byID.values.sorted { $0.files != $1.files ? $0.files > $1.files : $0.id < $1.id }
    }

    var isMultiCamera: Bool { cameraEntries.count > 1 }

    func cameraName(_ e: CameraEntry) -> String {
        cameraNames[e.id] ?? e.detected ?? defaultCamera
    }

    /// Câmera de cada grupo de origem, pra cópia e prévia (vazio quando o cartão tem uma câmera só: vale `camera`).
    var camerasByGroup: [String: String] {
        let entries = cameraEntries
        guard entries.count > 1 else { return [:] }
        var out: [String: String] = [:]
        for e in entries { for g in e.groups { out[g] = cameraName(e) } }
        return out
    }

    /// Grupos de origem das câmeras deixadas de fora.
    var excludedGroups: Set<String> {
        guard !excludedCameras.isEmpty else { return [] }
        return cameraEntries.filter { excludedCameras.contains($0.id) }.reduce(into: Set<String>()) { $0.formUnion($1.groups) }
    }
}

