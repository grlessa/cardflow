import Foundation

public struct OffloadPreview: Equatable {
    public var photos: Int
    public var videos: Int
    public var audios: Int
    public var cinema: Int                // pacotes de cinema preservados (verbatim)
    public var junk: Int                  // lixo/thumbnail ignorado (transparência)
    public var selectedCount: Int
    public var totalBytes: Int64          // bytes que cada destino vai receber
    public var unrecognized: [String]
    public var shortfalls: [SpaceChecker.Shortfall]
    public var alreadyPresent: Int = 0    // mídias já gravadas+conferidas no destino (= é uma RETOMADA)
    public var remainingBytes: Int64 = 0  // bytes que ainda falta copiar (total menos o que já está no destino)
}

extension CopyService {
    /// Escaneia e calcula o que SERIA copiado, sem copiar nada. Inclui checagem de espaço por destino.
    /// `capturedSince`: se dado, só inclui arquivos PLANOS capturados a partir dessa data (filtro "só
    /// hoje"). Bundles de cinema ficam de fora do filtro pra não quebrar um clipe pela metade.
    public func preview(cardRoot: URL, chosenMedia: Preset.Media.Kind, destinations: [URL],
                        capturedSince: Date? = nil, fastResume: Bool = true,
                        internalDestinations: Set<URL> = []) throws -> OffloadPreview {
        let all = try scanner.scan(cardRoot: cardRoot)
        let dateOK = Self.dateFilter(capturedSince)
        let selected = all.filter { isSelected($0, chosenMedia) && dateOK($0) }
        let photos = selected.filter { $0.type == .photo }.count
        let videos = selected.filter { $0.type == .video }.count
        let audios = selected.filter { $0.type == .audio }.count
        let cinema = PreservePlanner.bundleCount(selected)   // pacotes preservados selecionados
        let junk = all.filter { $0.type == .junk && !$0.preserve }.count
        let unrecognizedFiles = all.filter { $0.type == .unknown && !$0.preserve && dateOK($0) }
        let unrecognized = unrecognizedFiles.map(\.relPath).sorted()
        // não-reconhecidos também são copiados (rede de segurança #3) → contam no espaço necessário.
        let payload = selected + unrecognizedFiles
        let total = payload.reduce(Int64(0)) { $0 + $1.size }
        // checagem POR DESTINO descontando o que já está verificado lá (igual ao run) — senão uma
        // retomada num disco apertado deixaria o botão Iniciar bloqueado por "sem espaço".
        let eventoRoot = NameBuilder.sanitizePathComponent(preset.evento)
        let priorByDest = fastResume ? priorVerifiedRecords(destinations, eventoRoot: eventoRoot) : [:]
        let needByDest = requiredPerDestination(payload: payload, priorByDest: priorByDest, destinations: destinations)
        let shortfalls = try destinations.compactMap { dest -> SpaceChecker.Shortfall? in
            let margin = internalDestinations.contains(dest) ? Self.internalReserveBytes : marginBytes
            return try spaceChecker.check(requiredBytesPerDestination: needByDest[dest] ?? total,
                                          destinations: [dest], marginBytes: margin).first
        }
        // RETOMADA: quantas mídias selecionadas já estão verificadas em TODOS os destinos (= serão puladas).
        // >0 e < selecionadas → é uma retomada (o botão vira "Retomar").
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
        // bytes que ainda faltam: o total menos o que já está verificado em todos os destinos.
        let remainingBytes = total - payload.filter(presentEverywhere).reduce(Int64(0)) { $0 + $1.size }
        return OffloadPreview(photos: photos, videos: videos, audios: audios, cinema: cinema, junk: junk,
                              selectedCount: selected.count, totalBytes: total,
                              unrecognized: unrecognized, shortfalls: shortfalls,
                              alreadyPresent: alreadyPresent, remainingBytes: remainingBytes)
    }
}
