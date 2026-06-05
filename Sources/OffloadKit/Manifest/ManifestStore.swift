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
        destinationRoot.appendingPathComponent(eventName).appendingPathComponent(".cardflow")
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
        // escrita atômica: um crash no meio nunca deixa um manifesto JSON truncado/inválido no disco.
        try enc.encode(manifest).write(to: jsonURL, options: .atomic)
        let txtURL = dir.appendingPathComponent("manifest-\(stamp).txt")
        try Data(humanSummary(manifest).utf8).write(to: txtURL, options: .atomic)
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

    /// Todos os manifestos de um destino, varrendo as pastas de evento (`<dest>/<evento>/.cardflow`).
    /// Mais recente primeiro. Pro histórico de cópias na UI — rastreabilidade sobre infra já gravada.
    public func loadAllInDestination(_ destinationRoot: URL) -> [Manifest] {
        let fm = FileManager.default
        guard let events = try? fm.contentsOfDirectory(at: destinationRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [Manifest] = []
        for event in events where (try? event.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            out += (try? loadAll(eventRootIn: destinationRoot, eventName: event.lastPathComponent)) ?? []
        }
        return out.sorted { $0.finishedAt > $1.finishedAt }
    }

    public func humanSummary(_ m: Manifest) -> String {
        let cabecalho = m.interrupted
            ? "Offload INTERROMPIDO: \(m.presetName) · câmera \(m.camera)\n(registro parcial — o backup não terminou; mantenha o cartão como está)"
            : "Offload: \(m.presetName) · câmera \(m.camera)"
        return """
        \(cabecalho)
        Início: \(m.startedAt)  Fim: \(m.finishedAt)
        Cartão: \(m.source.volumeName) (\(m.source.fileCount) arquivos)
        \(m.totals.photos) foto(s) + \(m.totals.videos) vídeo(s) + \(m.totals.audio) áudio(s) + \(m.totals.cinema) clipe(s) de cinema
        Verificados: \(m.totals.verified) · Pulados: \(m.totals.skipped) · Falhas: \(m.totals.failed) · Sidecars: \(m.totals.sidecars)
        Não reconhecidos: \(m.unrecognized.count)
        """
    }
}
