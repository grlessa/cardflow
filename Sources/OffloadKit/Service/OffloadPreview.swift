import Foundation

public struct OffloadPreview: Equatable {
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
    public var alreadyPresentFromInterrupted: Int = 0 // subconjunto vindo só de manifesto interrompido
    public var remainingBytes: Int64 = 0  // bytes que ainda falta copiar (total menos o que já está no destino)
    public var lote: LoteDecision? = nil  // descarga detectada (nil quando a estrutura não usa {lote})

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

    public init(photos: Int, videos: Int, audios: Int, cinema: Int, junk: Int,
                selectedCount: Int, totalBytes: Int64,
                unrecognized: [String], shortfalls: [SpaceChecker.Shortfall],
                alreadyPresent: Int = 0, remainingBytes: Int64 = 0, lote: LoteDecision? = nil) {
        self.init(photos: photos, videos: videos, audios: audios, cinema: cinema, junk: junk,
                  junkPaths: [], selectedCount: selectedCount, totalBytes: totalBytes,
                  unrecognized: unrecognized, shortfalls: shortfalls,
                  alreadyPresent: alreadyPresent, alreadyPresentFromInterrupted: 0,
                  remainingBytes: remainingBytes, lote: lote)
    }
}

extension CopyService {
    /// Escaneia e calcula o que SERIA copiado, sem copiar nada. Inclui checagem de espaço por destino.
    /// `capturedIn`: se dado, só inclui arquivos planos capturados dentro do intervalo. Bundles de
    /// cinema ficam fora do filtro para não quebrar um clipe pela metade.
    public func preview(cardRoot: URL, chosenMedia: Preset.Media.Kind, destinations: [URL],
                        capturedIn: DateInterval? = nil, fastResume: Bool = true,
                        internalDestinations: Set<URL> = []) throws -> OffloadPreview {
        let destinations = destinations.reduce(into: [URL]()) { acc, u in if !acc.contains(u) { acc.append(u) } }   // dedup (igual ao run)
        let all = try scanner.scan(cardRoot: cardRoot)
        let dateOK = Self.dateFilter(capturedIn)
        let selected = all.filter { isSelected($0, chosenMedia) && dateOK($0) }
        let photos = selected.filter { $0.type == .photo }.count
        let videos = selected.filter { $0.type == .video }.count
        let audios = selected.filter { $0.type == .audio }.count
        let cinema = PreservePlanner.bundleCount(selected)   // pacotes preservados selecionados
        let junkFiles = all.filter { $0.type == .junk && !$0.preserve }
        let junk = junkFiles.count
        let junkPaths = junkFiles.map(\.relPath).sorted()
        let unrecognizedFiles = all.filter { $0.type == .unknown && !$0.preserve && dateOK($0) }
        let unrecognized = unrecognizedFiles.map(\.relPath).sorted()
        // não-reconhecidos também são copiados (rede de segurança #3) → contam no espaço necessário.
        let payload = selected + unrecognizedFiles
        let total = payload.reduce(Int64(0)) { $0 + $1.size }
        // checagem POR DESTINO descontando o que já está verificado lá (igual ao run) — senão uma
        // retomada num disco apertado deixaria o botão Iniciar bloqueado por "sem espaço".
        let eventoRoot = NameBuilder.sanitizePathComponent(preset.evento)
        let priorByDest = fastResume ? priorVerifiedRecords(destinations, eventoRoot: eventoRoot) : [:]
        let interruptedPresenceByDest = fastResume ? priorInterruptedPresence(destinations, eventoRoot: eventoRoot) : [:]
        let needByDest = requiredPerDestination(payload: payload, priorByDest: priorByDest, destinations: destinations)
        let shortfalls = try destinations.compactMap { dest -> SpaceChecker.Shortfall? in
            let margin = internalDestinations.contains(dest) ? Self.internalReserveBytes : marginBytes
            return try spaceChecker.check(requiredBytesPerDestination: needByDest[dest] ?? total,
                                          destinations: [dest], marginBytes: margin).first
        }
        // Quantas mídias selecionadas já estão verificadas em TODOS os destinos (= serão puladas).
        // A UI decide se isso é retomada, complemento de mídia ou cópia já completa.
        var presentByDest: [URL: [String: Int64]] = [:]
        for dest in destinations {
            var byteBySrc: [String: Int64] = [:]
            for f in (priorByDest[dest] ?? []) { byteBySrc[f.sourceRelPath] = f.bytes }
            presentByDest[dest] = byteBySrc
        }
        func presentEverywhere(_ f: MediaFile) -> Bool {
            !destinations.isEmpty && destinations.allSatisfy { presentByDest[$0]?[f.relPath] == f.size }
        }
        let alreadyPresent = selected.filter(presentEverywhere).count
        func presentFromInterruptedEverywhere(_ f: MediaFile) -> Bool {
            presentEverywhere(f) && destinations.allSatisfy { dest in
                interruptedPresenceByDest[dest]?[f.relPath] == true
            }
        }
        let alreadyPresentFromInterrupted = selected.filter(presentFromInterruptedEverywhere).count
        // bytes que ainda faltam: o total menos o que já está verificado em todos os destinos.
        let remainingBytes = total - payload.filter(presentEverywhere).reduce(Int64(0)) { $0 + $1.size }
        let loteDecision = resolveLote(selected: selected, destinations: destinations, eventoRoot: eventoRoot)
        return OffloadPreview(photos: photos, videos: videos, audios: audios, cinema: cinema, junk: junk,
                              junkPaths: junkPaths,
                              selectedCount: selected.count, totalBytes: total,
                              unrecognized: unrecognized, shortfalls: shortfalls,
                              alreadyPresent: alreadyPresent,
                              alreadyPresentFromInterrupted: alreadyPresentFromInterrupted,
                              remainingBytes: remainingBytes, lote: loteDecision)
    }

}
