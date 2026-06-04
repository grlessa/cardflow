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
}

extension CopyService {
    /// Escaneia e calcula o que SERIA copiado, sem copiar nada. Inclui checagem de espaço por destino.
    public func preview(cardRoot: URL, chosenMedia: Preset.Media.Kind, destinations: [URL]) throws -> OffloadPreview {
        let all = try scanner.scan(cardRoot: cardRoot)
        let selected = all.filter { isSelected($0, chosenMedia) }
        let photos = selected.filter { $0.type == .photo }.count
        let videos = selected.filter { $0.type == .video }.count
        let audios = selected.filter { $0.type == .audio }.count
        let cinema = PreservePlanner.bundleCount(selected)   // pacotes preservados selecionados
        let junk = all.filter { $0.type == .junk && !$0.preserve }.count
        let total = selected.reduce(Int64(0)) { $0 + $1.size }
        let unrecognized = all.filter { $0.type == .unknown && !$0.preserve }.map(\.relPath).sorted()
        let shortfalls = try spaceChecker.check(
            requiredBytesPerDestination: total, destinations: destinations, marginBytes: marginBytes
        )
        return OffloadPreview(photos: photos, videos: videos, audios: audios, cinema: cinema, junk: junk,
                              selectedCount: selected.count, totalBytes: total,
                              unrecognized: unrecognized, shortfalls: shortfalls)
    }
}
