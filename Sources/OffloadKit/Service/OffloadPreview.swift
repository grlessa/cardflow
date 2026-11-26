import Foundation

public struct OffloadPreview: Equatable, Sendable {
    public var photos: Int
    public var videos: Int
    public var audios: Int
    public var cinema: Int                // pacotes de cinema preservados (verbatim)
    public var junk: Int                  // lixo/thumbnail ignorado (transparência)
    public var junkPaths: [String] = []    // caminhos ignorados, para inspeção na UI
    public var selectedCount: Int
    public var totalBytes: Int64          // bytes que cada destino vai receber
    public var unrecognized: [String]
    public var shortfalls: [SpaceChecker.Shortfall]
    public var alreadyPresent: Int = 0    // mídias já gravadas+conferidas no destino (retomada ou complemento)
    public var alreadyPresentByType: [FileType: Int] = [:]
    public var alreadyPresentFromInterrupted: Int = 0 // subconjunto vindo só de manifesto interrompido
    public var remainingBytes: Int64 = 0  // bytes que ainda falta copiar (total menos o que já está no destino)
    public var lote: LoteDecision? = nil  // descarga detectada (nil quando a estrutura não usa {lote})
    /// O que fica no cartão SEM cópia por escolha do operador (mídia, filtro de data, irmãos desligados).
    /// Base do aviso do "Formatar ao terminar". Cinema conta por pacote (como em CardWipeCheck).
    public var excludedByChoice: [FileType: Int] = [:]

    public init(photos: Int, videos: Int, audios: Int, cinema: Int, junk: Int,
                junkPaths: [String] = [],
                selectedCount: Int, totalBytes: Int64,
                unrecognized: [String], shortfalls: [SpaceChecker.Shortfall],
                alreadyPresent: Int = 0, alreadyPresentFromInterrupted: Int = 0,
                remainingBytes: Int64 = 0, lote: LoteDecision? = nil) {
        self.photos = photos
        self.videos = videos
        self.audios = audios
        self.cinema = cinema
        self.junk = junk
        self.junkPaths = junkPaths
        self.selectedCount = selectedCount
        self.totalBytes = totalBytes
        self.unrecognized = unrecognized
        self.shortfalls = shortfalls
        self.alreadyPresent = alreadyPresent
        self.alreadyPresentFromInterrupted = alreadyPresentFromInterrupted
        self.remainingBytes = remainingBytes
        self.lote = lote
    }
}

extension CopyService {
    /// Escaneia e calcula o que SERIA copiado, sem copiar nada. Inclui checagem de espaço por destino.
    /// `capturedIn`: se dado, só inclui arquivos planos capturados dentro do intervalo. Bundles de
    /// cinema ficam fora do filtro para não quebrar um clipe pela metade.
    public func preview(cardRoot: URL, chosenMedia: Preset.Media.Kind, destinations: [URL],
                        capturedIn: DateInterval? = nil, excludedGroups: Set<String> = [], fastResume: Bool = true,
                        internalDestinations: Set<URL> = []) throws -> OffloadPreview {
        try preview(scanned: scanner.scan(cardRoot: cardRoot), cardRoot: cardRoot, chosenMedia: chosenMedia,
                    destinations: destinations, capturedIn: capturedIn, excludedGroups: excludedGroups,
                    fastResume: fastResume, internalDestinations: internalDestinations)
    }

    /// Prévia sobre uma lista do cartão JÁ varrida: trocar mídia, destino ou modelo recalcula sem reler o
    /// cartão (reler mantinha o volume ocupado e o macOS recusava ejetar).
    public func preview(scanned: [MediaFile], cardRoot: URL, chosenMedia: Preset.Media.Kind, destinations: [URL],
                        capturedIn: DateInterval? = nil, excludedGroups: Set<String> = [], fastResume: Bool = true,
                        internalDestinations: Set<URL> = []) throws -> OffloadPreview {
        let destinations = Self.normalizeDestinations(destinations)
        let internalPaths = Set(internalDestinations.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let all = scanned
        let dateOK = Self.choiceFilter(capturedIn, excludedGroups: excludedGroups)
        let dateOnlyOK = Self.dateFilter(capturedIn)
        let selected = all.filter { isSelected($0, chosenMedia) && dateOK($0) }
        let photos = selected.filter { $0.type == .photo }.count
        let videos = selected.filter { $0.type == .video }.count
        let audios = selected.filter { $0.type == .audio }.count
        let cinema = PreservePlanner.bundleCount(selected)   // pacotes preservados selecionados
        let junkFiles = all.filter { $0.type == .junk && !$0.preserve }
        let junk = junkFiles.count
        let junkPaths = junkFiles.map(\.relPath).sorted()
        let sidecars = all.filter { $0.type == .sidecar && !$0.preserve && dateOK($0) }
        let unrecognizedFiles = all.filter { $0.type == .unknown && !$0.preserve && dateOK($0) }
        let unrecognized = unrecognizedFiles.map(\.relPath).sorted()
        // não-reconhecidos também são copiados (rede de segurança #3) -> contam no espaço necessário.
        let payload = selected + unrecognizedFiles
        let spacePayload = payload + (preset.copySidecars == .aside ? sidecars : [])
        let total = payload.reduce(Int64(0)) { $0 + $1.size }
        // checagem POR DESTINO descontando o que já está verificado lá (igual ao run) — senão uma
        // retomada num disco apertado deixaria o botão Iniciar bloqueado por "sem espaço".
        let eventoRoot = Self.sanitizedEventRoot(preset.evento)
        let cardID = cardIdentity(cardRoot)
        let priorByDest = fastResume ? priorVerifiedRecords(destinations, eventoRoot: eventoRoot, scanned: all, cardID: cardID) : [:]
        let interruptedPresenceByDest = fastResume ? priorInterruptedPresence(destinations, eventoRoot: eventoRoot, scanned: all, cardID: cardID) : [:]
        let needByDest = requiredPerDestination(payload: spacePayload, priorByDest: priorByDest, destinations: destinations)
        let spaceItems = destinations.map { dest in
            (destination: dest,
             required: needByDest[dest] ?? spacePayload.reduce(Int64(0)) { $0 + $1.size },
             margin: internalPaths.contains(dest.path) ? Self.internalReserveBytes : marginBytes)
        }
        let shortfalls = try spaceChecker.checkPerDestination(spaceItems)
        // Quantas mídias selecionadas já estão verificadas em TODOS os destinos (= serão puladas).
        var presentByDest: [URL: [String: [Manifest.FileRecord]]] = [:]
        for dest in destinations {
            presentByDest[dest] = Dictionary(grouping: priorByDest[dest] ?? [], by: \.sourceRelPath)
        }
        func presentEverywhere(_ f: MediaFile) -> Bool {
            !destinations.isEmpty && destinations.allSatisfy { Self.isLikelyPresent(f, in: presentByDest[$0] ?? [:]) }
        }
        let presentSelected = selected.filter(presentEverywhere)
        let alreadyPresent = presentSelected.count
        var presentByType: [FileType: Int] = [:]
        var presentCinemaBundles = Set<String>()
        for f in presentSelected {
            if f.preserve {
                if presentCinemaBundles.insert(PreservePlanner.bundleKey(f.relPath)).inserted {
                    presentByType[.cinema, default: 0] += 1
                }
            } else {
                presentByType[f.type, default: 0] += 1
            }
        }
        func presentFromInterruptedEverywhere(_ f: MediaFile) -> Bool {
            presentEverywhere(f) && destinations.allSatisfy { dest in
                interruptedPresenceByDest[dest]?[f.relPath] == true
            }
        }
        let alreadyPresentFromInterrupted = selected.filter(presentFromInterruptedEverywhere).count
        // bytes que ainda faltam: o total menos o que já está verificado em todos os destinos.
        let remainingBytes = total - payload.filter(presentEverywhere).reduce(Int64(0)) { $0 + $1.size }
        let loteDecision = resolveLote(selected: selected, destinations: destinations, eventoRoot: eventoRoot)
        var excluded: [FileType: Int] = [:]
        var excludedCinemaBundles = Set<String>()
        let choices = WipeChoices(chosenMedia: chosenMedia, capturedIn: capturedIn, excludedGroups: excludedGroups)
        for f in all where !(f.type == .junk && !f.preserve)
            && !excludedGroups.contains(CameraGroups.key(for: f))
            && CardWipeCheck.isExcludedByChoice(f, service: self, choices: choices, preset: preset, dateOK: dateOnlyOK) {
            if f.preserve {
                if excludedCinemaBundles.insert(PreservePlanner.bundleKey(f.relPath)).inserted {
                    excluded[.cinema, default: 0] += 1
                }
            } else {
                excluded[f.type, default: 0] += 1
            }
        }
        var result = OffloadPreview(photos: photos, videos: videos, audios: audios, cinema: cinema, junk: junk,
                              junkPaths: junkPaths,
                              selectedCount: selected.count, totalBytes: total,
                              unrecognized: unrecognized, shortfalls: shortfalls,
                              alreadyPresent: alreadyPresent,
                              alreadyPresentFromInterrupted: alreadyPresentFromInterrupted,
                              remainingBytes: remainingBytes, lote: loteDecision)
        result.alreadyPresentByType = presentByType
        result.excludedByChoice = excluded
        return result
    }

}
