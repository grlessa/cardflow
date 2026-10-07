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

    /// Nome do JSON de uma cópia: carimbo de tempo (segundo) + fragmento do offloadId → dois cartões
    /// DIFERENTES no mesmo segundo não sobrescrevem um ao outro (mesmo cartão = mesmo id = idempotente).
    static func jsonFileName(for m: Manifest) -> String {
        "manifest-" + stamp.string(from: m.finishedAt) + "-" + CardFingerprint.shortID(m.offloadId) + ".json"
    }

    /// Grava o registro da cópia (JSON, na pasta oculta do projeto, que a retomada e o histórico leem) e
    /// refaz o relatório visível do projeto. Só o JSON define o sucesso: se o HTML falhar (disco cheio no
    /// último byte), a cópia conferida NÃO vira falha de registro.
    @discardableResult
    public func write(_ manifest: Manifest, eventRootIn destinationRoot: URL, eventName: String,
                      locale: Locale = Locale(identifier: "pt-BR")) throws -> URL {
        let dir = cardflowDir(in: destinationRoot, eventName: eventName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = dir.appendingPathComponent(Self.jsonFileName(for: manifest))
        // escrita atômica: um crash no meio nunca deixa um manifesto JSON truncado/inválido no disco.
        try enc.encode(manifest).write(to: jsonURL, options: .atomic)
        _ = try? writeProjectReport(eventRootIn: destinationRoot, eventName: eventName, locale: locale)
        return jsonURL
    }

    /// Refaz `<projeto>/Relatório Cardflow.html` a partir de todos os registros do projeto. Apaga a versão
    /// em outro idioma, se houver (o arquivo é gerado pelo app; senão trocar o idioma deixaria dois).
    @discardableResult
    public func writeProjectReport(eventRootIn destinationRoot: URL, eventName: String,
                                   locale: Locale = Locale(identifier: "pt-BR")) throws -> URL {
        let project = destinationRoot.appendingPathComponent(eventName)
        let manifests = try loadAll(eventRootIn: destinationRoot, eventName: eventName)
        let html = ProjectReport.html(manifests: manifests, projectName: eventName, locale: locale)
        let url = project.appendingPathComponent(ProjectReport.fileName(locale: locale))
        try Data(html.utf8).write(to: url, options: .atomic)
        for other in ProjectReport.allFileNames where other != url.lastPathComponent {
            try? FileManager.default.removeItem(at: project.appendingPathComponent(other))
        }
        return url
    }

    /// Relatório do projeto de um registro (`<projeto>/.cardflow/manifest-….json` → `<projeto>/Relatório….html`).
    public func reportURL(forManifestJSON json: URL, locale: Locale = Locale(identifier: "pt-BR")) -> URL {
        json.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(ProjectReport.fileName(locale: locale))
    }

    /// Marca nos manifestos (JSON) que o cartão foi formatado. Escrita atômica; devolve os que falharam.
    public func annotateCardFormatted(_ record: CardFormatRecord, manifestJSONPaths: [String],
                                      locale: Locale = Locale(identifier: "pt-BR")) -> [String] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var failed: [String] = []
        for path in manifestJSONPaths where path.hasSuffix(".json") {
            let url = URL(fileURLWithPath: path)
            do {
                var m = try dec.decode(Manifest.self, from: Data(contentsOf: url))
                m.cardFormatted = record
                try enc.encode(m).write(to: url, options: .atomic)
            } catch { failed.append(path) }
        }
        // o relatório de cada projeto afetado passa a mostrar "formatado em…".
        let projects = Set(manifestJSONPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() })
        for project in projects {
            _ = try? writeProjectReport(eventRootIn: project.deletingLastPathComponent(), eventName: project.lastPathComponent, locale: locale)
        }
        return failed
    }

    /// Registros do projeto com o caminho do JSON de cada um (pra anotar a formatação depois).
    public func loadAllWithURLs(eventRootIn destinationRoot: URL, eventName: String) -> [(url: URL, manifest: Manifest)] {
        let dir = cardflowDir(in: destinationRoot, eventName: eventName)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? dec.decode(Manifest.self, from: Data(contentsOf: url))).map { (url, $0) }
        }
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
}
