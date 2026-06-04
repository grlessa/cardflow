import Foundation

public enum OffloadError: Error, Equatable {
    case notEnoughSpace([SpaceChecker.Shortfall])
    case unsafeDestination(String)   // o caminho do preset tentou gravar FORA da pasta de destino
}

extension OffloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let shortfalls):
            let names = shortfalls.map { $0.destination.lastPathComponent }.joined(separator: ", ")
            return "Não há espaço suficiente em: \(names). Libere espaço no destino e tente de novo."
        case .unsafeDestination:
            return "Este preset tem uma estrutura de pastas inválida (tentou gravar fora da pasta de destino). Edite o preset e tente de novo."
        }
    }
}

public struct OffloadOutcome: Equatable {
    public var verifiedCount: Int
    public var failures: [String]
    public var unrecognized: [String]
    public var skipped: [String]
    public var sidecarsCopied: Int
    public var cardAlreadyCopied: Bool
    public var manifestPaths: [String]
    public var relocatedCinema: [String]
    public var manifestFailures: [String]   // destinos onde o manifesto NÃO pôde ser salvo (mídia ok)
    public init(verifiedCount: Int, failures: [String], unrecognized: [String], skipped: [String],
                sidecarsCopied: Int = 0, cardAlreadyCopied: Bool = false, manifestPaths: [String] = [],
                relocatedCinema: [String] = [], manifestFailures: [String] = []) {
        self.verifiedCount = verifiedCount; self.failures = failures
        self.unrecognized = unrecognized; self.skipped = skipped
        self.sidecarsCopied = sidecarsCopied; self.cardAlreadyCopied = cardAlreadyCopied
        self.manifestPaths = manifestPaths
        self.relocatedCinema = relocatedCinema
        self.manifestFailures = manifestFailures
    }
}

public struct CopyService {
    let preset: Preset
    let scanner: CardScanner
    let nameBuilder: NameBuilder
    private let resolver = CollisionResolver()
    let spaceChecker: SpaceChecker
    private let copier = FileCopier()
    let marginBytes: Int64
    private let clock: () -> Date
    private let activityKeeper: ActivityKeeping
    private let manifestStore: ManifestStore
    private let appVersion: String

    public init(preset: Preset, spaceProvider: FreeSpaceProviding,
                timeZone: TimeZone = .current, marginBytes: Int64 = 100 * 1024 * 1024,
                clock: @escaping () -> Date = { Date() },
                activityKeeper: ActivityKeeping = SystemActivityKeeper(),
                manifestStore: ManifestStore = ManifestStore(),
                appVersion: String = "0.1.0") {
        self.preset = preset
        self.scanner = CardScanner(classifier: FileClassifier(preset: preset))
        self.nameBuilder = NameBuilder(preset: preset, timeZone: timeZone)
        self.spaceChecker = SpaceChecker(provider: spaceProvider)
        self.marginBytes = marginBytes
        self.clock = clock
        self.activityKeeper = activityKeeper
        self.manifestStore = manifestStore
        self.appVersion = appVersion
    }

    func wants(_ type: FileType, _ chosen: Preset.Media.Kind) -> Bool {
        switch type {
        case .photo: return chosen == .photo || chosen == .both
        case .video: return chosen == .video || chosen == .both
        case .audio: return chosen == .audio || chosen == .both
        case .cinema: return chosen == .video || chosen == .both   // backstop: todo .cinema é preserve, mas se um vazar, não some
        default: return false
        }
    }

    /// Seleção ciente de preservação: um bundle entra/sai COESO. Sem este ramo, um irmão
    /// com type `.sidecar`/`.unknown` (XML, .rmd) seria dropado e o clipe quebraria.
    func isSelected(_ f: MediaFile, _ chosen: Preset.Media.Kind) -> Bool {
        f.preserve ? (chosen == .video || chosen == .both) : wants(f.type, chosen)
    }

    func disambiguationSuffixes(for file: MediaFile, sourceHash: UInt64) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = nameBuilder.timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return ["_" + f.string(from: file.captureDate)]
    }

    private struct CopyFileResult {
        var verified = 0
        var failures: [String] = []
        var fullyPresent = false
        var records: [Manifest.FileRecord] = []
    }

    /// Defesa final contra path traversal: garante que `rel` não escapa de NENHUM destino.
    /// `standardizedFileURL` resolve `..`/`.` de forma lexical; o destino é confiável (escolhido
    /// pelo usuário), então basta o caminho final continuar com o prefixo do destino. Mesmo que um
    /// preset não confiável passe pela validação, nada é gravado fora da pasta escolhida.
    private func assertContained(_ rel: String, in destinations: [URL]) throws {
        for dest in destinations {
            let target = dest.appendingPathComponent(rel).standardizedFileURL.path
            let base = dest.standardizedFileURL.path
            let baseSlash = base.hasSuffix("/") ? base : base + "/"
            guard target == base || target.hasPrefix(baseSlash) else {
                throw OffloadError.unsafeDestination(rel)
            }
        }
    }

    private func copyFile(_ file: MediaFile, desiredRel: String, destinations: [URL],
                          claimed: inout [URL: [String: UInt64]]) throws -> CopyFileResult {
        try assertContained(desiredRel, in: destinations)   // nada escreve fora do destino
        var result = CopyFileResult()
        let fm = FileManager.default

        // Caminho rápido: se NADA existe no caminho desejado (no disco ou já reivindicado
        // nesta sessão) em nenhum destino, não há colisão possível — grava direto e o hash
        // sai da própria cópia. Assim lê a origem UMA vez (sem o pré-hash redundante).
        let anyExisting = destinations.contains { dest in
            claimed[dest]?[desiredRel] != nil
                || fm.fileExists(atPath: dest.appendingPathComponent(desiredRel).path)
        }
        if !anyExisting {
            let targets = destinations.map { $0.appendingPathComponent(desiredRel) }
            let sourceHash = try copier.copy(source: file.sourceURL, to: targets)
            let hashHex = String(format: "%016llx", sourceHash)
            for dest in destinations {
                let url = dest.appendingPathComponent(desiredRel)
                if try copier.verify(expectedHash: sourceHash, fileAt: url) {
                    result.verified += 1
                    claimed[dest]?[desiredRel] = sourceHash
                    result.records.append(.init(sourceRelPath: file.relPath, destRelPath: desiredRel, type: file.type, bytes: file.size, xxhash64: hashHex, status: "verified"))
                } else {
                    try? fm.removeItem(at: url)   // verify falhou → remove o arquivo corrompido (não deixa lixo)
                    result.failures.append(desiredRel)
                }
            }
            return result
        }

        // Caminho com colisão possível: pré-hash + resolução determinística (não-sobrescrita).
        let sourceHash = try XXHash64.hash(fileAt: file.sourceURL)
        let suffixes = disambiguationSuffixes(for: file, sourceHash: sourceHash)
        let hashHex = String(format: "%016llx", sourceHash)

        var finalRelByDest: [URL: String] = [:]
        var presentByDest: [URL: Bool] = [:]
        for dest in destinations {
            let existingHash: (String) -> UInt64? = { rel in
                if let h = claimed[dest]?[rel] { return h }
                let url = dest.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try? XXHash64.hash(fileAt: url)
            }
            switch resolver.resolve(desired: desiredRel, sourceHash: sourceHash, existingHash: existingHash, suffixes: suffixes) {
            case .use(let p): finalRelByDest[dest] = p; presentByDest[dest] = false
            case .alreadyPresent(let p): finalRelByDest[dest] = p; presentByDest[dest] = true; claimed[dest]?[p] = sourceHash
            }
        }

        let writeTargets = destinations.compactMap { dest -> URL? in
            presentByDest[dest] == true ? nil : dest.appendingPathComponent(finalRelByDest[dest]!)
        }
        result.fullyPresent = writeTargets.isEmpty
        if !writeTargets.isEmpty { _ = try copier.copy(source: file.sourceURL, to: writeTargets) }

        for dest in destinations {
            let rel = finalRelByDest[dest]!
            let url = dest.appendingPathComponent(rel)
            if presentByDest[dest] == false {
                if try copier.verify(expectedHash: sourceHash, fileAt: url) {
                    result.verified += 1
                    claimed[dest]?[rel] = sourceHash
                    result.records.append(.init(sourceRelPath: file.relPath, destRelPath: rel, type: file.type, bytes: file.size, xxhash64: hashHex, status: "verified"))
                } else {
                    try? FileManager.default.removeItem(at: url)   // verify falhou → remove o corrompido
                    result.failures.append(rel)
                }
            } else {
                result.records.append(.init(sourceRelPath: file.relPath, destRelPath: rel, type: file.type, bytes: file.size, xxhash64: hashHex, status: "present"))
            }
        }
        return result
    }

    /// Decide a pasta-pai de um bundle de cinema: `<cartão>` ou, se algum arquivo do bundle já ocupar
    /// `{evento}/<pai>/<relPath>` em ALGUM destino com hash DIFERENTE, `<cartão> (2)`, `(3)`… Mantém o
    /// clipe inteiro junto e com nomes internos intactos (relink). Hasheia a origem só quando um caminho
    /// está ocupado (cartão novo = zero hash extra). Devolve o pai e se houve relocação (n > 1).
    private func resolveBundleParent(eventoRoot: String, cardName: String, bundle: [MediaFile],
                                     destinations: [URL], claimed: [URL: [String: UInt64]]) throws -> (parent: String, relocated: Bool) {
        let fm = FileManager.default
        var sourceHashes: [String: UInt64] = [:]
        func sourceHash(_ file: MediaFile) throws -> UInt64 {
            if let h = sourceHashes[file.relPath] { return h }
            let h = try XXHash64.hash(fileAt: file.sourceURL)
            sourceHashes[file.relPath] = h
            return h
        }
        var n = 1
        while true {
            let parent = n == 1 ? cardName : "\(cardName) (\(n))"
            var conflict = false
            outer: for file in bundle {
                let rel = "\(eventoRoot)/\(parent)/\(file.relPath)"
                for dest in destinations {
                    let existing: UInt64?
                    if let h = claimed[dest]?[rel] {
                        existing = h
                    } else {
                        let url = dest.appendingPathComponent(rel)
                        if fm.fileExists(atPath: url.path) {
                            guard let h = try? XXHash64.hash(fileAt: url) else { conflict = true; break outer }
                            existing = h
                        } else { existing = nil }
                    }
                    if let existing, existing != (try sourceHash(file)) { conflict = true; break outer }
                }
            }
            if !conflict { return (parent, n > 1) }
            n += 1
        }
    }

    public func run(cardRoot: URL, chosenMedia: Preset.Media.Kind,
                    destinations: [URL], camera: String,
                    sessionValues: [String: String] = [:],
                    onProgress: (OffloadProgress) -> Void = { _ in }) throws -> OffloadOutcome {
        let token = activityKeeper.begin(reason: "Cardflow offload")
        defer { activityKeeper.end(token) }

        // dedup defensivo: destinos repetidos (ex.: --to X --to X) quebrariam o `claimed` (chaves únicas).
        let destinations = destinations.reduce(into: [URL]()) { acc, u in if !acc.contains(u) { acc.append(u) } }

        let started = clock()
        // raiz do evento saneada pros caminhos LITERAIS (sidecar/manifesto), batendo com o
        // que o token {evento} produz na mídia — senão "Culto 09/06" iria pra duas árvores.
        let eventoRoot = NameBuilder.sanitizePathComponent(preset.evento)
        let cardName = NameBuilder.sanitizePathComponent(cardRoot.lastPathComponent)
        let all = try scanner.scan(cardRoot: cardRoot)
        let selected = all.filter { isSelected($0, chosenMedia) }
        let sidecars = all.filter { $0.type == .sidecar && !$0.preserve }
        let unrecognized = all.filter { $0.type == .unknown && !$0.preserve }.map(\.relPath).sorted()

        let required = selected.reduce(Int64(0)) { $0 + $1.size }
        let shortfalls = try spaceChecker.check(requiredBytesPerDestination: required, destinations: destinations, marginBytes: marginBytes)
        if !shortfalls.isEmpty { throw OffloadError.notEnoughSpace(shortfalls) }

        let totalFiles = selected.count + (preset.copySidecars == .aside ? sidecars.count : 0)
        onProgress(OffloadProgress(phase: .scanning, filesDone: 0, filesTotal: totalFiles, bytesDone: 0, bytesTotal: required))
        var bytesDone: Int64 = 0

        var claimed: [URL: [String: UInt64]] = Dictionary(uniqueKeysWithValues: destinations.map { ($0, [:]) })
        var verifiedCount = 0
        var failures: [String] = []
        var skipped: [String] = []
        var records: [Manifest.FileRecord] = []
        // contador ESTÁVEL: posição do arquivo entre TODA a mídia plana (foto/vídeo/áudio) do cartão,
        // ordenada — independe da seleção de mídia, então re-rodar com outra mídia não renumera (idempotência).
        let countable = all.filter { !$0.preserve && ($0.type == .photo || $0.type == .video || $0.type == .audio) }
        var counterIndex: [String: Int] = [:]
        for (i, f) in countable.enumerated() { counterIndex[f.relPath] = i + 1 }

        var processed = 0
        var relocatedCinema: [String] = []

        func copyOne(_ file: MediaFile, _ desiredRel: String) throws {
            let r = try copyFile(file, desiredRel: desiredRel, destinations: destinations, claimed: &claimed)
            verifiedCount += r.verified
            failures.append(contentsOf: r.failures)
            records.append(contentsOf: r.records)
            if r.fullyPresent { skipped.append(file.relPath) }
            bytesDone += file.size
            processed += 1
            onProgress(OffloadProgress(phase: .copying, filesDone: processed, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))
        }

        // 1) arquivos planos: achata + renomeia (contador estável por arquivo)
        for file in selected where !file.preserve {
            let context = NamingContext(camera: camera, counter: counterIndex[file.relPath] ?? 1,
                                        cardName: cardRoot.lastPathComponent, sessionValues: sessionValues)
            try copyOne(file, try nameBuilder.relativeDestination(for: file, context: context))
        }

        // 2) preservados: por BUNDLE, verbatim, desambiguando no nível da pasta do cartão
        var bundleOrder: [String] = []
        var bundles: [String: [MediaFile]] = [:]
        for file in selected where file.preserve {
            let key = PreservePlanner.bundleKey(file.relPath)
            if bundles[key] == nil { bundleOrder.append(key) }
            bundles[key, default: []].append(file)
        }
        for key in bundleOrder {
            let bundle = bundles[key]!
            let (parent, relocated) = try resolveBundleParent(
                eventoRoot: eventoRoot, cardName: cardName, bundle: bundle,
                destinations: destinations, claimed: claimed)
            if relocated { relocatedCinema.append(key) }
            for file in bundle {
                try copyOne(file, "\(eventoRoot)/\(parent)/\(file.relPath)")
            }
        }

        var sidecarsCopied = 0
        if preset.copySidecars == .aside {
            for file in sidecars {
                let desiredRel = "\(eventoRoot)/_cardflow/sidecars/\(file.relPath)"
                let r = try copyFile(file, desiredRel: desiredRel, destinations: destinations, claimed: &claimed)
                sidecarsCopied += r.verified
                failures.append(contentsOf: r.failures)
                records.append(contentsOf: r.records)   // sidecars também são listados no manifesto
                if r.fullyPresent { skipped.append(file.relPath) }   // sidecar já presente conta como pulado (re-run)
                processed += 1
                onProgress(OffloadProgress(phase: .copying, filesDone: processed, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))
            }
        }

        let finished = clock()
        let fingerprint = CardFingerprint.compute(files: selected)
        // Totais num local nomeado: a expressão inteira do Manifest estourava o orçamento de
        // type-check do Swift com mais um termo. Comportamento idêntico, só desmembrado.
        let totals = Manifest.Totals(
            photos: selected.filter { $0.type == .photo }.count,
            videos: selected.filter { $0.type == .video }.count,
            audio: selected.filter { $0.type == .audio }.count,
            cinema: PreservePlanner.bundleCount(selected),
            sidecars: records.filter { $0.type == .sidecar }.count,
            verified: verifiedCount, failed: failures.count, skipped: skipped.count)
        let manifest = Manifest(
            schemaVersion: 2, offloadId: fingerprint, appVersion: appVersion,
            presetName: preset.name, camera: camera, startedAt: started, finishedAt: finished,
            source: .init(volumeName: cardRoot.lastPathComponent, fingerprint: fingerprint, fileCount: selected.count, bytes: required),
            destinations: destinations.map(\.path),
            files: records, unrecognized: unrecognized,
            totals: totals
        )
        var manifestPaths: [String] = []
        var manifestFailures: [String] = []
        for dest in destinations {
            do {
                // defesa em profundidade: o manifesto é o único write fora do copyFile; garante
                // que ele também fica dentro do destino (eventoRoot já é saneado, mas não custa).
                try assertContained("\(eventoRoot)/_cardflow", in: [dest])
                let url = try manifestStore.write(manifest, eventRootIn: dest, eventName: eventoRoot)
                manifestPaths.append(url.path)
            } catch {
                manifestFailures.append(dest.lastPathComponent)   // mídia já verificada; só o registro falhou
            }
        }

        onProgress(OffloadProgress(phase: .done, filesDone: totalFiles, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))

        return OffloadOutcome(verifiedCount: verifiedCount, failures: failures,
                              unrecognized: unrecognized, skipped: skipped,
                              sidecarsCopied: sidecarsCopied, cardAlreadyCopied: false,
                              manifestPaths: manifestPaths, relocatedCinema: relocatedCinema,
                              manifestFailures: manifestFailures)
    }
}
