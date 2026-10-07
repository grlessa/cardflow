import Foundation

public struct WipeChoices: Equatable, Sendable {
    public var chosenMedia: Preset.Media.Kind
    public var capturedIn: DateInterval?
    /// Grupos de origem (`CameraGroups.key`) deixados de fora: a câmera de outra pessoa no mesmo cartão.
    public var excludedGroups: Set<String>
    public init(chosenMedia: Preset.Media.Kind, capturedIn: DateInterval?, excludedGroups: Set<String> = []) {
        self.chosenMedia = chosenMedia; self.capturedIn = capturedIn; self.excludedGroups = excludedGroups
    }
}

public struct CardWipeReport: Equatable, Sendable {
    public var saved = 0
    public var junk = 0
    public var excludedByChoice: [FileType: Int] = [:]
    public var notVerified: [String] = []
    public var canWipe: Bool { notVerified.isEmpty && saved > 0 }
    public var excludedTotal: Int { excludedByChoice.values.reduce(0, +) }
    public init() {}
}

/// TRAVA antes de formatar. Sem dicionário de marca: cada arquivo do cartão é (a) conferido em TODOS os
/// destinos (caminho + tamanho + data), (b) lixo que o classificador JÁ ignora, (c) deixado de fora pelas
/// escolhas daquela cópia (mídia, filtro de data, irmãos desligados) ou (d) não conferido, que bloqueia.
public enum CardWipeCheck {
    public static func evaluate(cardRoot: URL, preset: Preset, choices: WipeChoices,
                                destinations: [URL], manifestStore: ManifestStore = ManifestStore(),
                                cardIdentity: String? = nil) throws -> CardWipeReport {
        let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())
        let all = try CardScanner(classifier: FileClassifier(preset: preset)).scan(cardRoot: cardRoot)
        let eventoRoot = NameBuilder.sanitizePathComponent(preset.evento)
        let dateOK = CopyService.dateFilter(choices.capturedIn)
        // por destino: registros por origem (todos os manifestos do evento, inclusive o desta cópia)
        // só manifestos DESTE cartão (um cartão gêmeo de outra câmera não pode liberar a formatação)
        let cardFiles = Dictionary(all.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        var byDest: [URL: [String: [Manifest.FileRecord]]] = [:]
        for dest in destinations {
            let recs = ((try? manifestStore.loadAll(eventRootIn: dest, eventName: eventoRoot)) ?? [])
                .filter { CopyService.looksLikeSameCard($0, cardFiles: cardFiles,
                                                        cardID: cardIdentity ?? CardFingerprint.volumeIdentity(of: cardRoot)) }
                .flatMap(\.files).filter { $0.status == "verified" || $0.status == "present" }
            byDest[dest] = Dictionary(grouping: recs, by: \.sourceRelPath)
        }
        func savedEverywhere(_ f: MediaFile) -> Bool {
            !destinations.isEmpty && destinations.allSatisfy { dest in
                (byDest[dest]?[f.relPath] ?? []).contains { rec in
                    rec.matchesSource(size: f.size, date: f.captureDate) == true
                        && (try? dest.appendingPathComponent(rec.destRelPath).resourceValues(forKeys: [.fileSizeKey]))?.fileSize == Int(f.size)
                }
            }
        }
        var r = CardWipeReport()
        var cinemaBundlesExcluded = Set<String>()
        for f in all {
            if f.type == .junk && !f.preserve { r.junk += 1; continue }
            if savedEverywhere(f) { r.saved += 1; continue }
            // câmera deixada de fora (de outra pessoa no mesmo cartão): BLOQUEIA, formatar apagaria o material dela
            if choices.excludedGroups.contains(CameraGroups.key(for: f)) { r.notVerified.append(f.relPath); continue }
            if isExcludedByChoice(f, service: service, choices: choices, preset: preset, dateOK: dateOK) {
                if f.preserve {
                    let bundle = f.relPath.split(separator: "/").prefix(2).joined(separator: "/")
                    if cinemaBundlesExcluded.insert(bundle).inserted { r.excludedByChoice[.cinema, default: 0] += 1 }
                } else {
                    r.excludedByChoice[f.type, default: 0] += 1
                }
                continue
            }
            r.notVerified.append(f.relPath)
        }
        r.notVerified.sort()
        return r
    }

    /// Ficou de fora porque o operador escolheu: mídia não selecionada, fora do filtro de data, ou irmão
    /// (XML/THM…) com "copiar irmãos" desligado no modelo. Mesmas regras que a cópia usou.
    static func isExcludedByChoice(_ f: MediaFile, service: CopyService, choices: WipeChoices, preset: Preset,
                                   dateOK: (MediaFile) -> Bool) -> Bool {
        let byMedia = (f.preserve || [.photo, .video, .audio, .cinema].contains(f.type))
            && !service.isSelected(f, choices.chosenMedia)
        let byDate = !dateOK(f)
        let bySidecar = f.type == .sidecar && !f.preserve && preset.copySidecars == .skip
        return byMedia || byDate || bySidecar
    }
}
