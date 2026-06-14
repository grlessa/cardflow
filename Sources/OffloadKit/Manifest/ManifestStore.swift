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
    public func write(_ manifest: Manifest, eventRootIn destinationRoot: URL, eventName: String,
                      locale: Locale = Locale(identifier: "pt-BR")) throws -> URL {
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
        // o recibo .txt é arquivo GRAVADO → texto por idioma via tabela fixa por Locale (determinístico),
        // como turnoFolder/tipoFolder. O JSON acima NÃO muda — só o resumo humano segue o idioma.
        try Data(humanSummary(manifest, locale: locale).utf8).write(to: txtURL, options: .atomic)
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

    // O recibo .txt é arquivo GRAVADO no destino → strings por idioma vêm de uma tabela fixa por
    // Locale (determinístico), igual a turnoFolder/tipoFolder no NameBuilder. NÃO é catálogo de app.
    // Default pt-BR pra os testes/CLI que asseveram pt-BR seguirem verdes sem mudança.
    public func humanSummary(_ m: Manifest, locale: Locale = Locale(identifier: "pt-BR")) -> String {
        let t = ReceiptStrings(locale: locale)
        let cabecalho = m.interrupted
            ? "\(t.offloadInterrupted): \(m.presetName) · \(t.camera) \(m.camera)\n(\(t.partialNote))"
            : "\(t.offload): \(m.presetName) · \(t.camera) \(m.camera)"
        return """
        \(cabecalho)
        \(t.start): \(m.startedAt)  \(t.end): \(m.finishedAt)
        \(t.card): \(m.source.volumeName) (\(m.source.fileCount) \(t.files))
        \(m.totals.photos) \(t.photos) + \(m.totals.videos) \(t.videos) + \(m.totals.audio) \(t.audios) + \(m.totals.cinema) \(t.cinemaClips)
        \(t.verified): \(m.totals.verified) · \(t.skipped): \(m.totals.skipped) · \(t.failed): \(m.totals.failed) · \(t.sidecars): \(m.totals.sidecars)
        \(t.unrecognized): \(m.unrecognized.count)
        """
    }

    // Tabela fixa do recibo por idioma (pt/en/es). Determinística — entra em arquivo gravado.
    // Glossário do projeto: Cartão/Card/Tarjeta, Verificar/Verify/Verificar, Pasta/Folder/Carpeta.
    private struct ReceiptStrings {
        let offload, offloadInterrupted, partialNote, camera: String
        let start, end, card, files: String
        let photos, videos, audios, cinemaClips: String
        let verified, skipped, failed, sidecars, unrecognized: String

        init(locale: Locale) {
            switch locale.language.languageCode?.identifier ?? "pt" {
            case "en":
                offload = "Offload"
                offloadInterrupted = "Offload INTERRUPTED"
                partialNote = "partial record — the backup did not finish; keep the card as is"
                camera = "camera"
                start = "Start"; end = "End"; card = "Card"; files = "files"
                photos = "photo(s)"; videos = "video(s)"; audios = "audio(s)"; cinemaClips = "cinema clip(s)"
                verified = "Verified"; skipped = "Skipped"; failed = "Failed"
                sidecars = "Sidecars"; unrecognized = "Unrecognized"
            case "es":
                offload = "Descarga"
                offloadInterrupted = "Descarga INTERRUMPIDA"
                partialNote = "registro parcial — el backup no terminó; mantén la tarjeta como está"
                camera = "cámara"
                start = "Inicio"; end = "Fin"; card = "Tarjeta"; files = "archivos"
                photos = "foto(s)"; videos = "video(s)"; audios = "audio(s)"; cinemaClips = "clip(s) de cine"
                verified = "Verificados"; skipped = "Omitidos"; failed = "Fallos"
                sidecars = "Sidecars"; unrecognized = "No reconocidos"
            default:
                offload = "Offload"
                offloadInterrupted = "Offload INTERROMPIDO"
                partialNote = "registro parcial — o backup não terminou; mantenha o cartão como está"
                camera = "câmera"
                start = "Início"; end = "Fim"; card = "Cartão"; files = "arquivos"
                photos = "foto(s)"; videos = "vídeo(s)"; audios = "áudio(s)"; cinemaClips = "clipe(s) de cinema"
                verified = "Verificados"; skipped = "Pulados"; failed = "Falhas"
                sidecars = "Sidecars"; unrecognized = "Não reconhecidos"
            }
        }
    }
}
