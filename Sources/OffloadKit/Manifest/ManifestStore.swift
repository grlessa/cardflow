import Foundation

public struct ManifestStore {
    public init() {}

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private func cardflowDir(in destinationRoot: URL, eventName: String) -> URL {
        destinationRoot.appendingPathComponent(eventName).appendingPathComponent("_cardflow")
    }

    @discardableResult
    public func write(_ manifest: Manifest, eventRootIn destinationRoot: URL, eventName: String) throws -> URL {
        let dir = cardflowDir(in: destinationRoot, eventName: eventName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // nome = carimbo de tempo (segundo) + fragmento do offloadId → dois offloads de cartões
        // DIFERENTES no mesmo segundo não sobrescrevem um ao outro (mesmo cartão = mesmo id = idempotente).
        let stamp = Self.stamp.string(from: manifest.finishedAt) + "-" + String(manifest.offloadId.prefix(8))
        let jsonURL = dir.appendingPathComponent("manifest-\(stamp).json")
        try enc.encode(manifest).write(to: jsonURL)
        let txtURL = dir.appendingPathComponent("manifest-\(stamp).txt")
        try Data(humanSummary(manifest).utf8).write(to: txtURL)
        return jsonURL
    }

    public func loadAll(eventRootIn destinationRoot: URL, eventName: String) throws -> [Manifest] {
        let dir = cardflowDir(in: destinationRoot, eventName: eventName)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Manifest.self, from: Data(contentsOf: $0)) }
    }

    public func humanSummary(_ m: Manifest) -> String {
        """
        Offload: \(m.presetName) · câmera \(m.camera)
        Início: \(m.startedAt)  Fim: \(m.finishedAt)
        Cartão: \(m.source.volumeName) (\(m.source.fileCount) arquivos)
        \(m.totals.photos) foto(s) + \(m.totals.videos) vídeo(s) + \(m.totals.audio) áudio(s) + \(m.totals.cinema) clipe(s) de cinema
        Verificados: \(m.totals.verified) · Pulados: \(m.totals.skipped) · Falhas: \(m.totals.failed) · Sidecars: \(m.totals.sidecars)
        Não reconhecidos: \(m.unrecognized.count)
        """
    }
}
