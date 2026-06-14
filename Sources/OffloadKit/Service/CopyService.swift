import Foundation

public enum OffloadError: Error, Equatable {
    case notEnoughSpace([SpaceChecker.Shortfall])
    case unsafeDestination(String)   // o caminho do preset tentou gravar FORA da pasta de destino
    case cancelled                   // o usuário parou o backup no meio
    case diskFullDuringCopy          // um disco de destino encheu DURANTE a cópia (ENOSPC)
    case permissionDenied            // o macOS bloqueou o acesso à pasta de destino (TCC: Mesa/Documentos)
}

extension OffloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let shortfalls):
            let names = shortfalls.map { $0.destination.lastPathComponent }.joined(separator: ", ")
            return "Não há espaço suficiente em: \(names). Libere espaço no destino e tente de novo."
        case .unsafeDestination:
            return "Este preset tem uma estrutura de pastas inválida (tentou gravar fora da pasta de destino). Edite o preset e tente de novo."
        case .cancelled:
            return "Backup cancelado. Os arquivos já copiados estão no destino, mas o backup está incompleto — mantenha o cartão como está."
        case .diskFullDuringCopy:
            return "Um disco de destino encheu durante a cópia. Libere espaço e tente de novo. O cartão está intocado — mantenha-o como está."
        case .permissionDenied:
            return "O macOS bloqueou o acesso à pasta de destino. Libere em Ajustes › Privacidade › Arquivos e Pastas e tente de novo. O cartão está intocado."
        }
    }

    /// O erro (ou algum erro aninhado) é "disco cheio" (ENOSPC)? Modo de falha comum em campo.
    static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
        return false
    }

    /// O erro (ou algum aninhado) é "permissão negada" (TCC do macOS em Mesa/Documentos)? Vira mensagem
    /// clara apontando Ajustes › Privacidade, em vez de um erro de I/O genérico em inglês.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain &&
            (ns.code == CocoaError.fileReadNoPermission.rawValue || ns.code == CocoaError.fileWriteNoPermission.rawValue) { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionDenied(underlying) }
        return false
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
    /// Idioma efetivo da descarga — usado pro rótulo do lote nos bundles de cinema (verbatim, fora do template).
    let locale: Locale
    private let resolver = CollisionResolver()
    let spaceChecker: SpaceChecker
    private let copier: FileCopying
    let marginBytes: Int64

    /// Reserva extra exigida num destino no disco de SISTEMA (Mesa/Documentos): encher o interno
    /// trava o macOS, então pede uma folga bem maior que a margem dos discos externos.
    public static let internalReserveBytes: Int64 = 5 * 1024 * 1024 * 1024   // ~5 GB
    private let clock: () -> Date
    private let activityKeeper: ActivityKeeping
    private let manifestStore: ManifestStore
    private let appVersion: String

    public init(preset: Preset, spaceProvider: FreeSpaceProviding,
                timeZone: TimeZone = .current, marginBytes: Int64 = 100 * 1024 * 1024,
                clock: @escaping () -> Date = { Date() },
                activityKeeper: ActivityKeeping = SystemActivityKeeper(),
                manifestStore: ManifestStore = ManifestStore(),
                copier: FileCopying = FileCopier(),
                appVersion: String = OffloadKit.version,
                locale: Locale = Locale(identifier: "pt-BR")) {
        self.preset = preset
        self.scanner = CardScanner(classifier: FileClassifier(preset: preset))
        self.locale = locale
        self.nameBuilder = NameBuilder(preset: preset, timeZone: timeZone, locale: locale)
        self.spaceChecker = SpaceChecker(provider: spaceProvider)
        self.copier = copier
        self.marginBytes = marginBytes
        self.clock = clock
        self.activityKeeper = activityKeeper
        self.manifestStore = manifestStore
        self.appVersion = appVersion
    }

    /// Filtro de data do "só hoje": passa arquivos PLANOS capturados a partir de `since`. Bundles de
    /// cinema (preserve) passam sempre — filtrar por arquivo quebraria um clipe pela metade.
    static func dateFilter(_ since: Date?) -> (MediaFile) -> Bool {
        guard let since else { return { _ in true } }
        return { $0.preserve || $0.captureDate >= since }
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

    /// Registros já verificados/presentes em cada destino, lendo os manifestos anteriores deste evento.
    /// Base da retomada rápida (pular sem reler) e da checagem de espaço justa (descontar o que já lá está).
    func priorVerifiedRecords(_ destinations: [URL], eventoRoot: String) -> [URL: [Manifest.FileRecord]] {
        var out: [URL: [Manifest.FileRecord]] = [:]
        for dest in destinations {
            var recs: [Manifest.FileRecord] = []
            for m in ((try? manifestStore.loadAll(eventRootIn: dest, eventName: eventoRoot)) ?? []) {
                recs += m.files.filter { $0.status == "verified" || $0.status == "present" }
            }
            out[dest] = recs
        }
        return out
    }

    /// Para cada arquivo já presente, indica se a única prova dele vem de manifesto interrompido.
    /// Se também houver manifesto completo, o completo vence: esse arquivo não deve pintar como retomada.
    func priorInterruptedPresence(_ destinations: [URL], eventoRoot: String) -> [URL: [String: Bool]] {
        var out: [URL: [String: Bool]] = [:]
        for dest in destinations {
            var bySource: [String: Bool] = [:]
            for m in ((try? manifestStore.loadAll(eventRootIn: dest, eventName: eventoRoot)) ?? []) {
                for f in m.files where f.status == "verified" || f.status == "present" {
                    let existing = bySource[f.sourceRelPath]
                    bySource[f.sourceRelPath] = (existing ?? true) && m.interrupted
                }
            }
            out[dest] = bySource
        }
        return out
    }

    /// Bytes que cada destino ainda PRECISA receber: total do payload menos o que já está verificado lá
    /// (mesmo arquivo de origem, mesmo tamanho). Sem isto, retomar num disco apertado seria barrado por
    /// "sem espaço" contando o que já está no disco.
    func requiredPerDestination(payload: [MediaFile], priorByDest: [URL: [Manifest.FileRecord]],
                                destinations: [URL]) -> [URL: Int64] {
        var out: [URL: Int64] = [:]
        for dest in destinations {
            var alreadyBytes: [String: Int64] = [:]
            for f in (priorByDest[dest] ?? []) { alreadyBytes[f.sourceRelPath] = f.bytes }
            out[dest] = payload.reduce(Int64(0)) { acc, f in (alreadyBytes[f.relPath] == f.size) ? acc : acc + f.size }
        }
        return out
    }

    func disambiguationSuffixes(for file: MediaFile) -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = nameBuilder.timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "_" + f.string(from: file.captureDate)
        // variantes LEGÍVEIS pra rajada de fotos no mesmo segundo (base, base-2…base-9) antes de
        // cair no sufixo de hash hex (que é único mas feio). Cobre a maioria das rajadas reais.
        return [base] + (2...9).map { "\(base)-\($0)" }
    }

    /// Sufixo dos arquivos em escrita. A cópia grava em `<final>.cardflow-partial` e só renomeia
    /// pro nome FINAL (rename atômico, mesmo volume) DEPOIS de conferir byte a byte. Consequência:
    /// todo arquivo com nome final no destino está garantidamente íntegro — um crash/quit no meio
    /// deixa só um `.cardflow-partial`, nunca um arquivo de nome final pela metade.
    static let partialSuffix = ".cardflow-partial"
    private func partialURL(for finalURL: URL) -> URL {
        URL(fileURLWithPath: finalURL.path + Self.partialSuffix)
    }

    /// Um arquivo já gravado (no caminho parcial), a ser conferido e então renomeado pro nome final,
    /// em paralelo com as cópias seguintes.
    private struct PendingVerify {
        let url: URL          // nome FINAL (só passa a existir após a conferência)
        let tempURL: URL      // arquivo `.cardflow-partial` em que os bytes foram gravados
        let sourceURL: URL    // origem (pra recopiar numa falha transitória de verify)
        let expectedHash: UInt64
        let rel: String
        let sourceRel: String
        let type: FileType
        let bytes: Int64
        let hashHex: String
    }

    private struct CopyFileResult {
        var pending: [PendingVerify] = []                // gravados, a conferir
        var presentRecords: [Manifest.FileRecord] = []   // já presentes (não grava nem confere de novo)
        var fullyPresent = false
    }

    /// Categoria de um arquivo conferido — pra contar mídia, sidecar e não-reconhecido à parte.
    private enum VerifyCategory { case media, sidecar, unrecognized }

    /// Acumulador da verificação paralela. Tudo sob lock: a fila de fundo escreve aqui enquanto
    /// o laço de cópia segue. Reference type de propósito (evita acesso exclusivo a `var` capturado).
    private final class VerifyAccumulator {
        private let lock = NSLock()
        private var verified = 0             // mídia (foto/vídeo/áudio/cinema)
        private var sidecarVerified = 0      // sidecars-aside (contados à parte, como no fluxo antigo)
        private var unrecognizedVerified = 0 // não-reconhecidos copiados pra .cardflow/desconhecidos (rede de segurança)
        private var failures: [String] = []
        private var records: [Manifest.FileRecord] = []
        func addVerified(_ r: Manifest.FileRecord, category: VerifyCategory) {
            lock.lock()
            switch category {
            case .media: verified += 1
            case .sidecar: sidecarVerified += 1
            case .unrecognized: unrecognizedVerified += 1
            }
            records.append(r); lock.unlock()
        }
        func addFailure(_ rel: String) { lock.lock(); failures.append(rel); lock.unlock() }
        func addPresent(_ rs: [Manifest.FileRecord]) { guard !rs.isEmpty else { return }; lock.lock(); records.append(contentsOf: rs); lock.unlock() }
        func snapshot() -> (verified: Int, sidecarVerified: Int, unrecognizedVerified: Int, failures: [String], records: [Manifest.FileRecord]) {
            lock.lock(); defer { lock.unlock() }; return (verified, sidecarVerified, unrecognizedVerified, failures, records)
        }
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

    /// Remove `*.cardflow-partial` órfãos de um run interrompido (crash/quit/cabo). Escopo: a árvore
    /// do evento em cada destino — onde os parciais ficam — pra não varrer o disco inteiro a cada cópia.
    private func sweepOrphanPartials(eventoRoot: String, in destinations: [URL]) {
        let fm = FileManager.default
        for dest in destinations {
            let root = dest.appendingPathComponent(eventoRoot)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [], errorHandler: { _, _ in true }) else { continue }
            for case let u as URL in en where u.lastPathComponent.hasSuffix(Self.partialSuffix) {
                try? fm.removeItem(at: u)
            }
        }
    }

    private func copyFile(_ file: MediaFile, desiredRel: String, destinations: [URL],
                          claimed: inout [URL: [String: UInt64]],
                          verifiedByDest: [URL: [String: (bytes: Int64, hash: UInt64)]] = [:],
                          onCopiedBytes: (Int) -> Void = { _ in },
                          isCancelled: () -> Bool = { false }) throws -> CopyFileResult {
        try assertContained(desiredRel, in: destinations)   // nada escreve fora do destino
        var result = CopyFileResult()
        let fm = FileManager.default

        // RETOMADA RÁPIDA: se o manifesto anterior já conferiu este arquivo em TODOS os destinos
        // (mesmo caminho e tamanho) e ele ainda está lá com esse tamanho, pula sem reler — confiando
        // na verificação anterior. Evita reler dezenas de GB do cartão e do SSD na retomada.
        if !verifiedByDest.isEmpty {
            let vouchedEverywhere = destinations.allSatisfy { dest in
                guard let rec = verifiedByDest[dest]?[desiredRel], rec.bytes == file.size else { return false }
                let sz = (try? dest.appendingPathComponent(desiredRel).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                return sz == Int(file.size)
            }
            if vouchedEverywhere {
                result.fullyPresent = true
                for dest in destinations {
                    let rec = verifiedByDest[dest]![desiredRel]!
                    claimed[dest]?[desiredRel] = rec.hash
                    result.presentRecords.append(.init(sourceRelPath: file.relPath, destRelPath: desiredRel,
                        type: file.type, bytes: file.size, xxhash64: String(format: "%016llx", rec.hash), status: "present"))
                }
                return result
            }
        }

        // Caminho rápido: se NADA existe no caminho desejado (no disco ou já reivindicado
        // nesta sessão) em nenhum destino, não há colisão possível — grava direto e o hash
        // sai da própria cópia. Assim lê a origem UMA vez (sem o pré-hash redundante).
        let anyExisting = destinations.contains { dest in
            claimed[dest]?[desiredRel] != nil
                || fm.fileExists(atPath: dest.appendingPathComponent(desiredRel).path)
        }
        if !anyExisting {
            let finals = destinations.map { $0.appendingPathComponent(desiredRel) }
            // grava nos PARCIAIS; a conferência renomeia pro final só depois de bater o hash.
            let sourceHash = try copier.copy(source: file.sourceURL, to: finals.map(partialURL(for:)), onChunk: onCopiedBytes, isCancelled: isCancelled)
            let hashHex = String(format: "%016llx", sourceHash)
            for (i, dest) in destinations.enumerated() {
                // otimista: o parcial foi escrito (fsync já feito); a conferência confirma e promove em paralelo.
                claimed[dest]?[desiredRel] = sourceHash
                result.pending.append(PendingVerify(url: finals[i], tempURL: partialURL(for: finals[i]),
                                                    sourceURL: file.sourceURL, expectedHash: sourceHash, rel: desiredRel,
                                                    sourceRel: file.relPath, type: file.type, bytes: file.size, hashHex: hashHex))
            }
            return result
        }

        // Caminho com colisão possível: pré-hash + resolução determinística (não-sobrescrita).
        let sourceHash = try XXHash64.hash(fileAt: file.sourceURL)
        let suffixes = disambiguationSuffixes(for: file)
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
        // grava nos PARCIAIS; a conferência renomeia pro final só depois de bater o hash.
        if !writeTargets.isEmpty { _ = try copier.copy(source: file.sourceURL, to: writeTargets.map(partialURL(for:)), onChunk: onCopiedBytes, isCancelled: isCancelled) }

        for dest in destinations {
            let rel = finalRelByDest[dest]!
            let url = dest.appendingPathComponent(rel)
            if presentByDest[dest] == false {
                claimed[dest]?[rel] = sourceHash
                result.pending.append(PendingVerify(url: url, tempURL: partialURL(for: url),
                                                    sourceURL: file.sourceURL, expectedHash: sourceHash, rel: rel,
                                                    sourceRel: file.relPath, type: file.type, bytes: file.size, hashHex: hashHex))
            } else {
                result.presentRecords.append(.init(sourceRelPath: file.relPath, destRelPath: rel, type: file.type, bytes: file.size, xxhash64: hashHex, status: "present"))
            }
        }
        return result
    }

    /// Decide a pasta-pai de um bundle de cinema: `<cartão>` ou, se algum arquivo do bundle já ocupar
    /// `{evento}/<pai>/<relPath>` em ALGUM destino com hash DIFERENTE, `<cartão> (2)`, `(3)`… Mantém o
    /// clipe inteiro junto e com nomes internos intactos (relink). Hasheia a origem só quando um caminho
    /// está ocupado (cartão novo = zero hash extra). Devolve o pai e se houve relocação (n > 1).
    private func resolveBundleParent(eventoRoot: String, loteSeg: String, cardName: String, bundle: [MediaFile],
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
                let rel = "\(eventoRoot)/\(loteSeg)\(parent)/\(file.relPath)"
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

    /// Resolve o lote do cartão quando a estrutura usa {lote}. nil se o template não usa o token.
    /// Lê os manifestos já gravados no(s) destino(s) do evento e decide via LoteResolver (conteúdo).
    func resolveLote(selected: [MediaFile], destinations: [URL], eventoRoot: String) -> LoteDecision? {
        guard preset.folderStructure.contains("{lote}") else { return nil }
        let manifests = destinations.flatMap { (try? manifestStore.loadAll(eventRootIn: $0, eventName: eventoRoot)) ?? [] }
        let known = LoteResolver.knownLotes(from: manifests)
        let cardFiles = Set(selected.map { LoteFileKey(relPath: $0.relPath, bytes: $0.size) })
        return LoteResolver.resolve(cardFiles: cardFiles, known: known)
    }

    public func run(cardRoot: URL, chosenMedia: Preset.Media.Kind,
                    destinations: [URL], camera: String,
                    sessionValues: [String: String] = [:],
                    capturedSince: Date? = nil,
                    fastResume: Bool = true,
                    internalDestinations: Set<URL> = [],
                    isCancelled: () -> Bool = { false },
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
        let dateOK = Self.dateFilter(capturedSince)   // filtro "só hoje" (planos); cinema passa sempre
        let selected = all.filter { isSelected($0, chosenMedia) && dateOK($0) }
        let sidecars = all.filter { $0.type == .sidecar && !$0.preserve && dateOK($0) }
        // não-reconhecidos: copiados verbatim como REDE DE SEGURANÇA (#3) — podem ser footage de um
        // formato que ainda não conhecemos, então nunca são deixados pra trás em silêncio.
        let unrecognizedFiles = all.filter { $0.type == .unknown && !$0.preserve && dateOK($0) }
        let unrecognized = unrecognizedFiles.map(\.relPath).sorted()

        // lê os manifestos anteriores deste evento UMA vez: base da retomada rápida + checagem de espaço.
        let priorByDest = fastResume ? priorVerifiedRecords(destinations, eventoRoot: eventoRoot) : [:]
        // índice da retomada rápida (destRelPath → tamanho+hash): pula sem reler na cópia.
        var verifiedByDest: [URL: [String: (bytes: Int64, hash: UInt64)]] = [:]
        for (dest, recs) in priorByDest {
            var byDestRel: [String: (bytes: Int64, hash: UInt64)] = [:]
            for f in recs where !f.xxhash64.isEmpty {
                if let h = UInt64(f.xxhash64, radix: 16) { byDestRel[f.destRelPath] = (f.bytes, h) }
            }
            verifiedByDest[dest] = byDestRel
        }

        let payload = selected + unrecognizedFiles
        let required = payload.reduce(Int64(0)) { $0 + $1.size }   // total que PODE ser escrito (barra de progresso)
        // checagem POR DESTINO, descontando o que aquele disco já tem verificado (não será reescrito).
        let needByDest = requiredPerDestination(payload: payload, priorByDest: priorByDest, destinations: destinations)
        let shortfalls: [SpaceChecker.Shortfall] = try destinations.compactMap { dest -> SpaceChecker.Shortfall? in
            let margin = internalDestinations.contains(dest) ? Self.internalReserveBytes : marginBytes
            return try spaceChecker.check(requiredBytesPerDestination: needByDest[dest] ?? required,
                                          destinations: [dest], marginBytes: margin).first
        }
        if !shortfalls.isEmpty { throw OffloadError.notEnoughSpace(shortfalls) }

        let totalFiles = selected.count + unrecognizedFiles.count + (preset.copySidecars == .aside ? sidecars.count : 0)
        onProgress(OffloadProgress(phase: .scanning, filesDone: 0, filesTotal: totalFiles, bytesDone: 0, bytesTotal: required))
        var bytesDone: Int64 = 0

        var claimed: [URL: [String: UInt64]] = Dictionary(uniqueKeysWithValues: destinations.map { ($0, [:]) })
        var skipped: [String] = []
        // contador ESTÁVEL: posição do arquivo entre TODA a mídia plana (foto/vídeo/áudio) do cartão,
        // ordenada — independe da seleção de mídia, então re-rodar com outra mídia não renumera (idempotência).
        let countable = all.filter { !$0.preserve && ($0.type == .photo || $0.type == .video || $0.type == .audio) }
        var counterIndex: [String: Int] = [:]
        for (i, f) in countable.enumerated() { counterIndex[f.relPath] = i + 1 }

        // VERIFICAÇÃO EM PARALELO: a cópia escreve (com fsync) e segue; a conferência (ler de volta +
        // hash) roda numa fila serial, sobrepondo a leitura de um arquivo com a cópia do próximo.
        // Recupera quase todo o tempo do "ler de volta" SEM abrir mão da verificação byte a byte.
        let acc = VerifyAccumulator()
        let verifyQueue = DispatchQueue(label: "br.com.cardflow.verify")   // serial: confere 1 por vez
        let verifyGroup = DispatchGroup()
        let copier = self.copier   // captura imutável (não captura self na fila de fundo)
        func enqueueVerify(_ pv: PendingVerify, category: VerifyCategory) {
            verifyGroup.enter()
            verifyQueue.async {
                let fm = FileManager.default
                var ok = (try? copier.verify(expectedHash: pv.expectedHash, fileAt: pv.tempURL)) ?? false
                // retry de falha TRANSITÓRIA (glitch de cabo USB / hiccup de controlador): recopia da
                // origem e reconfere até 2 vezes antes de desistir. Não é perda (a falha real ainda é
                // gritada na Uia); é resiliência pros casos que somem na 2ª tentativa.
                var extraAttempts = 0
                while !ok && extraAttempts < 2 {
                    extraAttempts += 1
                    _ = try? copier.copy(source: pv.sourceURL, to: [pv.tempURL], onChunk: { _ in }, isCancelled: { false })
                    ok = (try? copier.verify(expectedHash: pv.expectedHash, fileAt: pv.tempURL)) ?? false
                }
                if ok {
                    do {
                        // promove o parcial pro nome final (rename atômico). NUNCA sobrescreve: se o
                        // final já existir (não deveria, colisão já foi resolvida), trata como falha
                        // em vez de apagar um arquivo bom.
                        try fm.moveItem(at: pv.tempURL, to: pv.url)
                        acc.addVerified(.init(sourceRelPath: pv.sourceRel, destRelPath: pv.rel, type: pv.type, bytes: pv.bytes, xxhash64: pv.hashHex, status: "verified"), category: category)
                    } catch {
                        acc.addFailure(pv.rel)
                        try? fm.removeItem(at: pv.tempURL)
                    }
                } else {
                    acc.addFailure(pv.rel)
                    try? fm.removeItem(at: pv.tempURL)   // verify falhou → remove o parcial corrompido
                }
                verifyGroup.leave()
            }
        }

        var processed = 0
        var relocatedCinema: [String] = []

        func copyOne(_ file: MediaFile, _ desiredRel: String, countsBytes: Bool = true, category: VerifyCategory = .media) throws {
            // cancelamento COOPERATIVO: checa entre arquivos, nunca no meio de um (não deixa arquivo
            // pela metade). Lança .cancelled → o mesmo catch que trata interrupção drena/limpa/registra.
            if isCancelled() { throw OffloadError.cancelled }
            let base = bytesDone
            var sinceReport: Int64 = 0
            // progresso DENTRO do arquivo: a barra anda enquanto um vídeo grande copia (limita a
            // emissão a cada ~32 MB pra não disparar milhares de updates de UI num arquivo de 18 GB).
            let r = try copyFile(file, desiredRel: desiredRel, destinations: destinations, claimed: &claimed,
                                 verifiedByDest: verifiedByDest,
                                 onCopiedBytes: { chunk in
                bytesDone += Int64(chunk)
                sinceReport += Int64(chunk)
                if sinceReport >= 32 * 1024 * 1024 {
                    sinceReport = 0
                    onProgress(OffloadProgress(phase: .copying, filesDone: processed, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))
                }
            }, isCancelled: isCancelled)
            acc.addPresent(r.presentRecords)
            if r.fullyPresent { skipped.append(file.relPath) }
            for pv in r.pending { enqueueVerify(pv, category: category) }   // confere em paralelo enquanto o próximo já copia
            bytesDone = countsBytes ? base + file.size : base   // sidecar não conta no total de bytes
            processed += 1
            onProgress(OffloadProgress(phase: .copying, filesDone: processed, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))
        }

        // limpa parciais de um run anterior interrompido antes de começar (hygiene; o nome final
        // já é seguro por si só, mas isso evita acúmulo de `.cardflow-partial`).
        sweepOrphanPartials(eventoRoot: eventoRoot, in: destinations)

        // fase vira "Copiando" já no começo (mesmo antes do 1º bloco), pra sumir o "Escaneando".
        if !selected.isEmpty {
            onProgress(OffloadProgress(phase: .copying, filesDone: 0, filesTotal: totalFiles, bytesDone: 0, bytesTotal: required))
        }

        // resolve o lote (descarga) UMA vez por offload; nil quando a estrutura não usa {lote}.
        let loteNumero = resolveLote(selected: selected, destinations: destinations, eventoRoot: eventoRoot)?.numero
        // segmento de pasta do lote pros bundles de cinema (que não passam pelo template): "Lote NN/" ou "".
        // posiciona o lote logo após o evento (cinema já é verbatim sob <evento>/<cartão>), então separa
        // os clipes de cinema por descarga igual aos arquivos planos.
        let loteSeg = loteNumero.map { NameBuilder.loteLabel(for: locale) + " " + String(format: "%02d", $0) + "/" } ?? ""
        do {
            // 1) arquivos planos: achata + renomeia (contador estável por arquivo)
            for file in selected where !file.preserve {
                let context = NamingContext(camera: camera, counter: counterIndex[file.relPath] ?? 1,
                                            cardName: cardRoot.lastPathComponent, sessionValues: sessionValues, lote: loteNumero)
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
                    eventoRoot: eventoRoot, loteSeg: loteSeg, cardName: cardName, bundle: bundle,
                    destinations: destinations, claimed: claimed)
                if relocated { relocatedCinema.append(key) }
                for file in bundle {
                    try copyOne(file, "\(eventoRoot)/\(loteSeg)\(parent)/\(file.relPath)")
                }
            }

            // 3) sidecars (só se a política for .aside): vão pra .cardflow/sidecars; não contam bytes
            //    nem entram no verifiedCount de mídia (são contados à parte em sidecarsCopied).
            if preset.copySidecars == .aside {
                for file in sidecars {
                    try copyOne(file, "\(eventoRoot)/.cardflow/sidecars/\(file.relPath)", countsBytes: false, category: .sidecar)
                }
            }

            // 4) não-reconhecidos: rede de segurança (#3). Copia verbatim+conferido pra
            //    .cardflow/desconhecidos, pra um formato novo nunca sumir sem aviso. Conta no verde
            //    como "desconhecido" (à parte da mídia), e uma falha aqui também impede formatar.
            for file in unrecognizedFiles {
                try copyOne(file, "\(eventoRoot)/.cardflow/desconhecidos/\(file.relPath)", countsBytes: true, category: .unrecognized)
            }
        } catch {
            // Corte no meio (disco cheio, cartão arrancado, espaço acabou). SEMPRE drena a verificação
            // antes de sair: senão closures async continuariam renomeando/removendo arquivos no disco
            // DEPOIS de run() retornar (corrida perigosa num app cujo trabalho é não mexer errado em footage).
            verifyGroup.wait()
            // limpa o parcial que estourou no meio da escrita (os conferidos já viraram nome final;
            // os reprovados já foram removidos pela própria verificação).
            sweepOrphanPartials(eventoRoot: eventoRoot, in: destinations)
            // manifesto PARCIAL marcado como interrompido: trilha do que foi salvo+conferido até aqui.
            let snap = acc.snapshot()
            let records = snap.records.sorted { $0.destRelPath < $1.destRelPath }
            let fp = CardFingerprint.compute(files: selected)
            let totals = Manifest.Totals(
                photos: selected.filter { $0.type == .photo }.count,
                videos: selected.filter { $0.type == .video }.count,
                audio: selected.filter { $0.type == .audio }.count,
                cinema: PreservePlanner.bundleCount(selected),
                sidecars: records.filter { $0.type == .sidecar }.count,
                verified: snap.verified, failed: snap.failures.count, skipped: skipped.count)
            let partialManifest = Manifest(
                schemaVersion: 2, offloadId: fp, appVersion: appVersion,
                presetName: preset.name, camera: camera, startedAt: started, finishedAt: clock(),
                source: .init(volumeName: cardRoot.lastPathComponent, fingerprint: fp, fileCount: selected.count, bytes: required),
                destinations: destinations.map(\.path), files: records, unrecognized: unrecognized,
                totals: totals, interrupted: true, lote: loteNumero)
            for dest in destinations {
                guard (try? assertContained("\(eventoRoot)/.cardflow", in: [dest])) != nil else { continue }
                _ = try? manifestStore.write(partialManifest, eventRootIn: dest, eventName: eventoRoot, locale: locale)
            }
            // cancelamento no meio de um arquivo (botão Parar) chega como CancellationError → normaliza.
            if error is CancellationError { throw OffloadError.cancelled }
            // disco cheio é um modo de falha comum em campo: troca o erro de I/O genérico (em inglês,
            // incompreensível pro leigo) por uma mensagem clara apontando o que fazer.
            if OffloadError.isDiskFull(error) { throw OffloadError.diskFullDuringCopy }
            if OffloadError.isPermissionDenied(error) { throw OffloadError.permissionDenied }
            throw error
        }

        // espera a verificação terminar (a maior parte já rodou em paralelo com as cópias acima).
        onProgress(OffloadProgress(phase: .verifying, filesDone: processed, filesTotal: totalFiles, bytesDone: bytesDone, bytesTotal: required))
        verifyGroup.wait()
        let snap = acc.snapshot()
        let verifiedCount = snap.verified
        let sidecarsCopied = snap.sidecarVerified
        let failures = snap.failures
        let records = snap.records.sorted { $0.destRelPath < $1.destRelPath }   // ordem determinística

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
        var manifestPaths: [String] = []
        var manifestFailures: [String] = []
        let fm = FileManager.default
        for dest in destinations {
            do {
                // defesa em profundidade: o manifesto é o único write fora do copyFile; garante
                // que ele também fica dentro do destino (eventoRoot já é saneado, mas não custa).
                try assertContained("\(eventoRoot)/.cardflow", in: [dest])
                // #21: manifesto FIEL por disco — só lista os arquivos que REALMENTE estão neste destino.
                // No modo 2 SSDs, se um arquivo verificou num disco e falhou no outro, cada manifesto
                // reflete o seu próprio disco, em vez de os dois afirmarem ter o arquivo.
                let destFiles = records.filter { fm.fileExists(atPath: dest.appendingPathComponent($0.destRelPath).path) }
                var destTotals = totals
                // verified conta só MÍDIA: sidecars e não-reconhecidos vivem sob .cardflow/ e têm contagem
                // própria; cinema (fora de .cardflow) conta. (type sozinho não basta: .RMD de cinema é .unknown.)
                destTotals.verified = destFiles.filter { $0.status == "verified" && !$0.destRelPath.contains("/.cardflow/") }.count
                let destManifest = Manifest(
                    schemaVersion: 2, offloadId: fingerprint, appVersion: appVersion,
                    presetName: preset.name, camera: camera, startedAt: started, finishedAt: finished,
                    source: .init(volumeName: cardRoot.lastPathComponent, fingerprint: fingerprint, fileCount: selected.count, bytes: required),
                    destinations: destinations.map(\.path),
                    files: destFiles, unrecognized: unrecognized, totals: destTotals, lote: loteNumero)
                let url = try manifestStore.write(destManifest, eventRootIn: dest, eventName: eventoRoot, locale: locale)
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
