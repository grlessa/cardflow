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
        // comprovante HTML (abre no navegador, imprime/PDF) — a "Prova da cópia" que a UI abre.
        // try? de propósito: o JSON+TXT já definem o sucesso do registro; se só o HTML falhar (disco
        // cheio no último byte), a cópia verificada NÃO vira falha de manifesto (openReport cai no txt).
        let htmlURL = dir.appendingPathComponent("manifest-\(stamp).html")
        try? Data(htmlReport(manifest, locale: locale).utf8).write(to: htmlURL, options: .atomic)
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

    /// Relatório HTML (comprovante de cópia) — abre no navegador, dá pra imprimir/salvar PDF. Mostra o
    /// veredito, os metadados e a tabela de CADA arquivo com hash + status: a prova da cópia byte a byte.
    public func htmlReport(_ m: Manifest, locale: Locale = Locale(identifier: "pt-BR")) -> String {
        let t = ReceiptStrings(locale: locale)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let df = DateFormatter(); df.locale = locale; df.dateStyle = .medium; df.timeStyle = .short
        let dateStr = df.string(from: m.finishedAt)
        let fp = m.source.fingerprint.isEmpty ? "" : " · \(t.lblFingerprint) \(String(m.source.fingerprint.prefix(6)))"
        let lang = locale.language.languageCode?.identifier ?? "pt"

        let verdict: (cls: String, icon: String, title: String, sub: String)
        if m.interrupted {
            verdict = ("warn", "&#9888;", esc(t.interruptedTitle), "\(m.totals.verified) \(esc(t.copiedAndVerified))")
        } else if m.totals.failed > 0 {
            verdict = ("fail", "&#10007;", "\(m.totals.failed) \(esc(t.failuresWord))", "\(m.totals.verified) \(esc(t.copiedAndVerified))")
        } else {
            verdict = ("ok", "&#10003;", "\(m.totals.verified) \(esc(t.files)) \(esc(t.copiedAndVerified))",
                       "\(m.totals.skipped) \(esc(t.alreadyAtDest)) · \(m.totals.failed) \(esc(t.failed.lowercased()))")
        }

        func typeLabel(_ ft: FileType) -> String {
            switch ft {
            case .photo: return t.typePhoto; case .video: return t.typeVideo; case .audio: return t.typeAudio
            case .cinema: return t.typeCinema; case .sidecar: return t.typeSidecar; default: return t.typeOther
            }
        }
        let rows = m.files.map { f in
            "<tr><td>\(esc(f.destRelPath))</td><td class=mut>\(esc(typeLabel(f.type)))</td><td class=num>\(Format.humanBytes(f.bytes))</td><td class=hash>\(esc(String(f.xxhash64.prefix(12))))</td><td class=ok>&#10003;</td></tr>"
        }.joined(separator: "\n")
        let loteStr = m.lote.map { " · \(t.lblLote) \(String(format: "%02d", $0))" } ?? ""
        let dests = m.destinations.map(esc).joined(separator: " · ")
        let secTitle = "\(t.files) \(t.verified.lowercased())"

        return """
        <!DOCTYPE html><html lang="\(lang)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(t.reportTitle)) · \(esc(m.presetName))</title>
        <style>
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        body { font-family: -apple-system, system-ui, "Segoe UI", sans-serif; color: #1a1a1a; background: #f4f4f6; margin: 0; padding: 28px; }
        .sheet { max-width: 760px; margin: 0 auto; background: #fff; border-radius: 12px; overflow: hidden; box-shadow: 0 6px 24px #00000014; }
        .head { display: flex; justify-content: space-between; align-items: center; padding: 18px 26px; border-bottom: 1px solid #eee; }
        .brand { font-weight: 700; font-size: 17px; letter-spacing: -0.3px; }
        .head .sub { color: #888; font-size: 13px; }
        .verdict { margin: 22px 26px; border-radius: 10px; padding: 16px 18px; display: flex; gap: 13px; align-items: center; }
        .verdict .ic { font-size: 24px; line-height: 1; }
        .verdict .vt { font-weight: 700; font-size: 16px; }
        .verdict .vs { font-size: 13px; margin-top: 2px; opacity: 0.85; }
        .ok { background: #e8f7ee; border: 1px solid #b6e6c7; color: #1a7f3c; }
        .warn { background: #fdf3e3; border: 1px solid #f0d9a8; color: #8a5a12; }
        .fail { background: #fdecec; border: 1px solid #f2bcbc; color: #a11111; }
        .meta { margin: 0 26px; display: grid; grid-template-columns: 1fr 1fr; gap: 10px 30px; font-size: 13px; }
        .meta .k { color: #999; }
        .meta .v { color: #222; }
        h2.sec { margin: 22px 26px 8px; font-size: 12px; font-weight: 700; color: #999; text-transform: uppercase; letter-spacing: 0.6px; }
        .tablewrap { margin: 0 26px; border: 1px solid #eee; border-radius: 8px; overflow: hidden; }
        table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
        thead th { background: #fafafa; color: #888; text-align: left; font-weight: 600; padding: 8px 11px; }
        tbody td { padding: 6px 11px; border-top: 1px solid #f1f1f1; color: #333; }
        td.mut { color: #888; } td.num { white-space: nowrap; } td.hash { font-family: ui-monospace, "SF Mono", monospace; color: #666; }
        td.ok { color: #1a7f3c; text-align: center; }
        .foot { margin: 18px 26px 22px; font-size: 12px; color: #888; line-height: 1.5; border-top: 1px solid #eee; padding-top: 14px; }
        @media print { body { background: #fff; padding: 0; } .sheet { box-shadow: none; max-width: none; } }
        </style></head><body>
        <div class="sheet">
          <div class="head"><div class="brand">Cardflow</div><div class="sub">\(esc(t.reportTitle))</div></div>
          <div class="verdict \(verdict.cls)"><div class="ic">\(verdict.icon)</div><div><div class="vt">\(verdict.title)</div><div class="vs">\(verdict.sub)</div></div></div>
          <div class="meta">
            <div><div class="k">\(esc(t.lblDate))</div><div class="v">\(esc(dateStr))</div></div>
            <div><div class="k">\(esc(t.card))</div><div class="v">\(esc(m.source.volumeName))\(esc(fp))</div></div>
            <div><div class="k">\(esc(t.camera.capitalized))</div><div class="v">\(esc(m.camera.isEmpty ? "—" : m.camera))</div></div>
            <div><div class="k">\(esc(t.lblModel))</div><div class="v">\(esc(m.presetName))</div></div>
            <div><div class="k">\(esc(t.lblDest))</div><div class="v">\(dests)</div></div>
            <div><div class="k">\(esc(t.lblApp))</div><div class="v">Cardflow \(esc(m.appVersion))\(esc(loteStr))</div></div>
          </div>
          <h2 class="sec">\(esc(secTitle))</h2>
          <div class="tablewrap"><table>
            <thead><tr><th>\(esc(t.thFile))</th><th>\(esc(t.thType))</th><th>\(esc(t.thSize))</th><th>\(esc(t.thHash))</th><th>&#10003;</th></tr></thead>
            <tbody>
        \(rows)
            </tbody>
          </table></div>
          <div class="foot">\(esc(t.footerNote))<br>\(esc(t.generatedBy)) \(esc(m.appVersion)).</div>
        </div></body></html>
        """
    }

    // Tabela fixa do recibo por idioma (pt/en/es). Determinística — entra em arquivo gravado.
    // Glossário do projeto: Cartão/Card/Tarjeta, Verificar/Verify/Verificar, Pasta/Folder/Carpeta.
    private struct ReceiptStrings {
        let offload, offloadInterrupted, partialNote, camera: String
        let start, end, card, files: String
        let photos, videos, audios, cinemaClips: String
        let verified, skipped, failed, sidecars, unrecognized: String
        // rótulos do relatório HTML (comprovante)
        let reportTitle, copiedAndVerified, interruptedTitle, failuresWord, alreadyAtDest: String
        let lblDate, lblModel, lblDest, lblApp, lblLote, lblFingerprint: String
        let thFile, thType, thSize, thHash: String
        let typePhoto, typeVideo, typeAudio, typeCinema, typeSidecar, typeOther: String
        let footerNote, generatedBy: String

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
                reportTitle = "Copy receipt"
                copiedAndVerified = "copied and verified byte for byte"
                interruptedTitle = "Copy interrupted. Partial record."
                failuresWord = "verification failures"; alreadyAtDest = "were already at the destination"
                lblDate = "Date"; lblModel = "Folder template"; lblDest = "Destination"
                lblApp = "App"; lblLote = "Batch"; lblFingerprint = "fingerprint"
                thFile = "File"; thType = "Type"; thSize = "Size"; thHash = "Hash"
                typePhoto = "photo"; typeVideo = "video"; typeAudio = "audio"
                typeCinema = "cinema"; typeSidecar = "sidecar"; typeOther = "other"
                footerNote = "Each file was copied and re-read at the destination; the xxHash64 matches the source, proving a byte-for-byte identical copy."
                generatedBy = "Generated by Cardflow"
            case "es":
                offload = "Descarga"
                offloadInterrupted = "Descarga INTERRUMPIDA"
                partialNote = "registro parcial — el backup no terminó; mantén la tarjeta como está"
                camera = "cámara"
                start = "Inicio"; end = "Fin"; card = "Tarjeta"; files = "archivos"
                photos = "foto(s)"; videos = "video(s)"; audios = "audio(s)"; cinemaClips = "clip(s) de cine"
                verified = "Verificados"; skipped = "Omitidos"; failed = "Fallos"
                sidecars = "Sidecars"; unrecognized = "No reconocidos"
                reportTitle = "Comprobante de copia"
                copiedAndVerified = "copiados y verificados byte a byte"
                interruptedTitle = "Copia interrumpida. Registro parcial."
                failuresWord = "fallos de verificación"; alreadyAtDest = "ya estaban en el destino"
                lblDate = "Fecha"; lblModel = "Modelo de carpetas"; lblDest = "Destino"
                lblApp = "App"; lblLote = "Lote"; lblFingerprint = "huella"
                thFile = "Archivo"; thType = "Tipo"; thSize = "Tamaño"; thHash = "Hash"
                typePhoto = "foto"; typeVideo = "video"; typeAudio = "audio"
                typeCinema = "cine"; typeSidecar = "adjunto"; typeOther = "otro"
                footerNote = "Cada archivo se copió y se releyó en el destino; el xxHash64 coincide con el origen, probando una copia idéntica byte a byte."
                generatedBy = "Generado por Cardflow"
            default:
                offload = "Offload"
                offloadInterrupted = "Offload INTERROMPIDO"
                partialNote = "registro parcial — o backup não terminou; mantenha o cartão como está"
                camera = "câmera"
                start = "Início"; end = "Fim"; card = "Cartão"; files = "arquivos"
                photos = "foto(s)"; videos = "vídeo(s)"; audios = "áudio(s)"; cinemaClips = "clipe(s) de cinema"
                verified = "Verificados"; skipped = "Pulados"; failed = "Falhas"
                sidecars = "Sidecars"; unrecognized = "Não reconhecidos"
                reportTitle = "Comprovante de cópia"
                copiedAndVerified = "copiados e verificados byte a byte"
                interruptedTitle = "Cópia interrompida. Registro parcial."
                failuresWord = "falhas na verificação"; alreadyAtDest = "já estavam no destino"
                lblDate = "Data"; lblModel = "Modelo de pastas"; lblDest = "Destino"
                lblApp = "App"; lblLote = "Lote"; lblFingerprint = "impressão"
                thFile = "Arquivo"; thType = "Tipo"; thSize = "Tamanho"; thHash = "Hash"
                typePhoto = "foto"; typeVideo = "vídeo"; typeAudio = "áudio"
                typeCinema = "cinema"; typeSidecar = "anexo"; typeOther = "outro"
                footerNote = "Cada arquivo foi copiado e relido no destino; o hash xxHash64 bate com o da origem, provando cópia idêntica byte a byte."
                generatedBy = "Gerado por Cardflow"
            }
        }
    }
}
