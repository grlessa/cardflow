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
            return "Cópia cancelada. Os arquivos já copiados estão no destino, mas a cópia ficou incompleta. Mantenha o cartão como está."
        case .diskFullDuringCopy:
            return "Um disco de destino encheu durante a cópia. Libere espaço e tente de novo. O cartão continua intacto, mantenha-o como está."
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
    /// Arquivos de mídia que ficaram no cartão porque a câmera deles foi deixada de fora.
    public var cameraFilesLeft: Int
    public init(verifiedCount: Int, failures: [String], unrecognized: [String], skipped: [String],
                sidecarsCopied: Int = 0, cardAlreadyCopied: Bool = false, manifestPaths: [String] = [],
                relocatedCinema: [String] = [], manifestFailures: [String] = [], cameraFilesLeft: Int = 0) {
        self.cameraFilesLeft = cameraFilesLeft
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

    /// Filtro de data: passa arquivos planos capturados dentro de `interval`. Bundles de cinema
    /// (`preserve`) passam sempre para não quebrar um clipe pela metade.
    static func dateFilter(_ interval: DateInterval?) -> (MediaFile) -> Bool {
        guard let interval else { return { _ in true } }
        return { file in
            file.preserve || (file.captureDate >= interval.start && file.captureDate < interval.end)
        }
    }

    /// Filtro das escolhas de origem: data (`dateFilter`) e câmeras deixadas de fora (grupos de origem).
    static func choiceFilter(_ interval: DateInterval?, excludedGroups: Set<String>) -> (MediaFile) -> Bool {
        let dateOK = dateFilter(interval)
        guard !excludedGroups.isEmpty else { return dateOK }
        return { dateOK($0) && !excludedGroups.contains(CameraGroups.key(for: $0)) }
    }

    /// Identidade do cartão: a definida pra teste, ou o UUID do volume da origem.
    public var cardIdentityOverride: String?
    func cardIdentity(_ root: URL) -> String? { cardIdentityOverride ?? CardFingerprint.volumeIdentity(of: root) }

    /// Tipo do dispositivo da origem, pro ícone do relatório: disco interno vira pasta; fora de volume
    /// montado (pasta comum, teste), nil.
    static func sourceMediaKind(_ root: URL) -> String? {
        guard let t = PhysicalDisk.traits(for: root) else { return nil }
        return t.isInternalDevice ? MediaKind.folder.rawValue : t.mediaKind.rawValue
    }

    /// Id da cópia: hash dos arquivos, mais a identidade do cartão quando há (cartões gêmeos não colidem).
    static func offloadID(files: [MediaFile], cardID: String?) -> String {
        let fp = CardFingerprint.compute(files: files)
        return cardID.map { fp + "-" + $0 } ?? fp
    }

    /// Os arquivos de mídia que uma cópia com estas escolhas levaria (mesma regra do `run`). Pra prévia
    /// da organização na interface.
    public func selectedFiles(_ scanned: [MediaFile], chosenMedia: Preset.Media.Kind, capturedIn: DateInterval?,
                              excludedGroups: Set<String> = []) -> [MediaFile] {
        let dateOK = Self.choiceFilter(capturedIn, excludedGroups: excludedGroups)
        return scanned.filter { isSelected($0, chosenMedia) && dateOK($0) }
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

    /// Esta cópia registrada é DESTE cartão? Pelo menos 90% dos arquivos dela continuam no cartão com o
    /// mesmo caminho, tamanho e data. Vale pra retomada, lote seguinte e complemento (o cartão não foi
    /// formatado, então o que foi salvo continua lá). Barra o "cartão gêmeo": outra câmera igual no
    /// mesmo evento, com DSC00001 do mesmo tamanho (RAW sem compressão) e do mesmo segundo, cujo
    /// registro faria o app pular o arquivo e liberar formatar sem ter copiado.
    public static func looksLikeSameCard(_ m: Manifest, cardFiles: [String: MediaFile], cardID: String? = nil) -> Bool {
        // os dois lados com identidade de volume: só vale se for o MESMO cartão.
        if let a = m.source.volumeID, let b = cardID { return a == b }
        let recs = m.files.filter { ($0.status == "verified" || $0.status == "present") && !$0.destRelPath.contains("/.cardflow/") }
        guard !recs.isEmpty else { return false }
        // registro antigo sem data (nil) conta pelo tamanho; a cópia ainda confere o hash nesse caso.
        let hits = recs.filter { r in
            guard let f = cardFiles[r.sourceRelPath] else { return false }
            return r.matchesSource(size: f.size, date: f.captureDate) != false
        }.count
        return hits * 10 >= recs.count * 9
    }

    /// Manifestos anteriores do projeto em cada destino que são deste cartão (ver `looksLikeSameCard`).
    func priorManifests(_ destinations: [URL], eventoRoot: String, scanned: [MediaFile], cardID: String?) -> [URL: [Manifest]] {
        let cardFiles = Dictionary(scanned.map { ($0.relPath, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [URL: [Manifest]] = [:]
        for dest in destinations {
            out[dest] = ((try? manifestStore.loadAll(eventRootIn: dest, eventName: eventoRoot)) ?? [])
                .filter { Self.looksLikeSameCard($0, cardFiles: cardFiles, cardID: cardID) }
        }
        return out
    }

    /// Registros já verificados/presentes em cada destino, dos manifestos anteriores DESTE cartão.
    /// Base da retomada rápida (pular sem reler) e da checagem de espaço justa (descontar o que já lá está).
    func priorVerifiedRecords(_ destinations: [URL], eventoRoot: String, scanned: [MediaFile], cardID: String?) -> [URL: [Manifest.FileRecord]] {
        priorManifests(destinations, eventoRoot: eventoRoot, scanned: scanned, cardID: cardID).mapValues { ms in
            ms.flatMap { $0.files.filter { $0.status == "verified" || $0.status == "present" } }
        }
    }

    /// Para cada arquivo já presente, indica se a única prova dele vem de manifesto interrompido.
    /// Se também houver manifesto completo, o completo vence: esse arquivo não deve pintar como retomada.
    func priorInterruptedPresence(_ destinations: [URL], eventoRoot: String, scanned: [MediaFile], cardID: String?) -> [URL: [String: Bool]] {
        priorManifests(destinations, eventoRoot: eventoRoot, scanned: scanned, cardID: cardID).mapValues { ms in
            var bySource: [String: Bool] = [:]
            for m in ms {
                for f in m.files where f.status == "verified" || f.status == "present" {
                    let existing = bySource[f.sourceRelPath]
                    bySource[f.sourceRelPath] = (existing ?? true) && m.interrupted
                }
            }
            return bySource
        }
    }

    /// Bytes que cada destino ainda PRECISA receber: total do payload menos o que já está verificado lá
    /// (mesmo arquivo de origem, mesmo tamanho). Sem isto, retomar num disco apertado seria barrado por
    /// "sem espaço" contando o que já está no disco.
    func requiredPerDestination(payload: [MediaFile], priorByDest: [URL: [Manifest.FileRecord]],
                                destinations: [URL]) -> [URL: Int64] {
        var out: [URL: Int64] = [:]
        for dest in destinations {
            let bySrc = Dictionary(grouping: priorByDest[dest] ?? [], by: \.sourceRelPath)
            out[dest] = payload.reduce(Int64(0)) { acc, f in
                Self.isLikelyPresent(f, in: bySrc) ? acc : acc + f.size
            }
        }
        return out
    }

    /// Estimativa (sem ler nada) de que `file` já está salvo segundo os registros do destino: mesmo
    /// caminho de origem, tamanho e data. Registro antigo sem data conta como presente; a cópia, que
    /// não pode errar, confere o hash nesse caso. Usado pela prévia e pela conta de espaço.
    static func isLikelyPresent(_ file: MediaFile, in recordsBySource: [String: [Manifest.FileRecord]]) -> Bool {
        (recordsBySource[file.relPath] ?? []).contains {
            $0.matchesSource(size: file.size, date: file.captureDate) ?? true
        }
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
        let sourceDate: Date
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
            // padroniza a BASE primeiro e monta o alvo a partir dela: o macOS tira o "/private" de um
            // caminho só quando ele existe, então padronizar os dois separados fazia um destino em
            // /private/tmp (que existe) não bater com o alvo (que ainda não existe) e a cópia era recusada.
            let baseURL = dest.standardizedFileURL
            let target = baseURL.appendingPathComponent(rel).standardizedFileURL.path
            let base = baseURL.path
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

    /// Registro de um manifesto anterior, indexado pra decidir pulos sem reler o destino.
    struct PriorRecord {
        let record: Manifest.FileRecord
        let hash: UInt64
    }

    private func copyFile(_ file: MediaFile, desiredRel: String, destinations: [URL],
                          claimed: inout [URL: [String: UInt64]],
                          verifiedByDest: [URL: [String: PriorRecord]] = [:],
                          presentBySrcByDest: [URL: [String: [PriorRecord]]] = [:],
                          onCopiedBytes: (Int) -> Void = { _ in },
                          isCancelled: () -> Bool = { false }) throws -> CopyFileResult {
        try assertContained(desiredRel, in: destinations)   // nada escreve fora do destino
        var result = CopyFileResult()
        let fm = FileManager.default

        // IDENTIDADE DA ORIGEM: um registro antigo só vale pra ESTE arquivo do cartão se tamanho e data
        // baterem. Caminho+tamanho sozinhos confundem cartões diferentes (duas câmeras iguais, RAW sem
        // compressão com tamanho fixo, numeração reiniciada) e o app liberaria formatar sem ter copiado.
        // Manifesto antigo (sem data): confere o hash da origem, lido no máximo uma vez.
        var sourceHashCache: UInt64?
        func sourceHashOnce() throws -> UInt64 {
            if let h = sourceHashCache { return h }
            let h = try XXHash64.hash(fileAt: file.sourceURL)
            sourceHashCache = h
            return h
        }
        func describesThisFile(_ prior: PriorRecord) -> Bool {
            switch prior.record.matchesSource(size: file.size, date: file.captureDate) {
            case .some(let match): return match
            case .none: return (try? sourceHashOnce()) == prior.hash
            }
        }
        func destHasSize(_ dest: URL, _ rel: String) -> Bool {
            let sz = (try? dest.appendingPathComponent(rel).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return sz == Int(file.size)
        }
        func present(_ rel: String, hash: UInt64) -> Manifest.FileRecord {
            .init(sourceRelPath: file.relPath, destRelPath: rel, type: file.type, bytes: file.size,
                  xxhash64: String(format: "%016llx", hash), status: "present", sourceDate: file.captureDate)
        }

        // PRESENÇA POR CONTEÚDO: este MESMO arquivo de origem já foi gravado+conferido num offload
        // anterior deste evento, possivelmente em OUTRO lote (cartão não formatado que voltou pro lote
        // seguinte). Reconhece como já salvo, no lugar onde já está, e NÃO recopia pro caminho novo,
        // senão o material antigo seria duplicado no lote novo. Confia na verificação anterior.
        // Só mídia PLANA: bundles de cinema (preserve) têm realocação própria por colisão de conteúdo
        // (BMD → BMD (2)) e não podem ser pulados por coincidência de caminho da origem.
        if !file.preserve && !presentBySrcByDest.isEmpty {
            var found: [URL: PriorRecord] = [:]
            for dest in destinations {
                guard let hit = (presentBySrcByDest[dest]?[file.relPath] ?? [])
                    .first(where: { describesThisFile($0) && destHasSize(dest, $0.record.destRelPath) }) else { break }
                found[dest] = hit
            }
            if found.count == destinations.count {
                result.fullyPresent = true
                for dest in destinations {
                    let prior = found[dest]!
                    claimed[dest]?[prior.record.destRelPath] = prior.hash
                    result.presentRecords.append(present(prior.record.destRelPath, hash: prior.hash))
                }
                return result
            }
        }

        // RETOMADA RÁPIDA: se o manifesto anterior já conferiu este arquivo em TODOS os destinos
        // (mesmo caminho de destino, mesma origem) e ele ainda está lá com esse tamanho, pula sem reler
        // o destino, confiando na verificação anterior. Evita reler dezenas de GB na retomada.
        if !verifiedByDest.isEmpty {
            let vouchedEverywhere = destinations.allSatisfy { dest in
                guard let prior = verifiedByDest[dest]?[desiredRel], describesThisFile(prior) else { return false }
                return destHasSize(dest, desiredRel)
            }
            if vouchedEverywhere {
                result.fullyPresent = true
                for dest in destinations {
                    let prior = verifiedByDest[dest]![desiredRel]!
                    claimed[dest]?[desiredRel] = prior.hash
                    result.presentRecords.append(present(desiredRel, hash: prior.hash))
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
                                                    sourceRel: file.relPath, type: file.type, bytes: file.size, hashHex: hashHex,
                                                    sourceDate: file.captureDate))
            }
            return result
        }

        // Caminho com colisão possível: pré-hash + resolução determinística (não-sobrescrita).
        let sourceHash = try sourceHashOnce()   // reaproveita se a checagem de origem já leu
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
                                                    sourceRel: file.relPath, type: file.type, bytes: file.size, hashHex: hashHex,
                                                    sourceDate: file.captureDate))
            } else {
                result.presentRecords.append(present(rel, hash: sourceHash))
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

    /// Chaves de mídia plana (foto/vídeo/áudio — cinema é tipo próprio, fica fora) já registradas nos
    /// manifestos do evento em lotes DIFERENTES de `excludingLote`. Base da numeração POR LOTE do
    /// {contador}: o que pertence a outros lotes não conta na posição local deste lote (reinício por
    /// lote), e a contagem disso é o offset de continuação (opt-in). Dedup por origem+tamanho.
    func priorLoteMediaKeys(destinations: [URL], eventoRoot: String, excludingLote: Int?) -> Set<LoteFileKey> {
        var keys = Set<LoteFileKey>()
        for dest in destinations {
            for m in ((try? manifestStore.loadAll(eventRootIn: dest, eventName: eventoRoot)) ?? []) {
                guard m.lote != excludingLote else { continue }
                for f in m.files where (f.status == "verified" || f.status == "present")
                    && (f.type == .photo || f.type == .video || f.type == .audio)
                    && !f.destRelPath.contains("/.cardflow/") {
                    keys.insert(LoteFileKey(relPath: f.sourceRelPath, bytes: f.bytes))
                }
            }
        }
        return keys
    }

    public func run(cardRoot: URL, chosenMedia: Preset.Media.Kind,
                    destinations: [URL], camera: String,
                    cameras: [String: String] = [:],
                    excludedGroups: Set<String> = [],
                    sessionValues: [String: String] = [:],
                    capturedIn: DateInterval? = nil,
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
        let dateOK = Self.choiceFilter(capturedIn, excludedGroups: excludedGroups)
        let selected = all.filter { isSelected($0, chosenMedia) && dateOK($0) }
        // câmera de cada arquivo: a do grupo dele (cartão com várias câmeras), senão a do cartão
        func cameraOf(_ f: MediaFile) -> String { cameras[CameraGroups.key(for: f)] ?? camera }
        // câmeras deixadas de fora: o que delas ficou no cartão trava a formatação
        let leftByCamera = all.filter { (f: MediaFile) in
            (f.preserve || [.photo, .video, .audio, .cinema].contains(f.type)) && excludedGroups.contains(CameraGroups.key(for: f))
        }
        let keptCameras = Array(Set(leftByCamera.map { cameras[CameraGroups.key(for: $0)] ?? CameraGroups.key(for: $0) }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let manifestCamera = cameras.isEmpty ? camera
            : Array(Set(selected.map(cameraOf))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ")
        let sidecars = all.filter { $0.type == .sidecar && !$0.preserve && dateOK($0) }
        // o que fica no cartão por escolha (mídia/data), pro relatório: mesma regra da prévia e da checagem de formatar.
        let wipeChoices = WipeChoices(chosenMedia: chosenMedia, capturedIn: capturedIn, excludedGroups: excludedGroups)
        let excludedByChoice = all.filter { !($0.type == .junk && !$0.preserve)
            && CardWipeCheck.isExcludedByChoice($0, service: self, choices: wipeChoices, preset: preset, dateOK: dateOK) }
            .map(\.relPath).sorted()
        // não-reconhecidos: copiados verbatim como REDE DE SEGURANÇA (#3) — podem ser footage de um
        // formato que ainda não conhecemos, então nunca são deixados pra trás em silêncio.
        let unrecognizedFiles = all.filter { $0.type == .unknown && !$0.preserve && dateOK($0) }
        let unrecognized = unrecognizedFiles.map(\.relPath).sorted()

        // lê os manifestos anteriores deste evento UMA vez: base da retomada rápida + checagem de espaço.
        let cardID = cardIdentity(cardRoot)
        let sourceKind = Self.sourceMediaKind(cardRoot)
        let priorByDest = fastResume ? priorVerifiedRecords(destinations, eventoRoot: eventoRoot, scanned: all, cardID: cardID) : [:]
        // índices dos pulos (ver copyFile): retomada rápida por caminho de DESTINO e presença por
        // conteúdo por caminho de ORIGEM (vários registros por origem: cartões diferentes podem ter o
        // mesmo DSC00001; quem decide qual é o certo é a identidade tamanho+data).
        var verifiedByDest: [URL: [String: PriorRecord]] = [:]
        var presentBySrcByDest: [URL: [String: [PriorRecord]]] = [:]
        for (dest, recs) in priorByDest {
            var byDestRel: [String: PriorRecord] = [:]
            var bySrc: [String: [PriorRecord]] = [:]
            for f in recs where !f.xxhash64.isEmpty {
                guard let h = UInt64(f.xxhash64, radix: 16) else { continue }
                let prior = PriorRecord(record: f, hash: h)
                byDestRel[f.destRelPath] = prior
                bySrc[f.sourceRelPath, default: []].append(prior)
            }
            verifiedByDest[dest] = byDestRel
            presentBySrcByDest[dest] = bySrc
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
        // resolve o lote (descarga) UMA vez por offload; nil quando a estrutura não usa {lote}.
        let loteDecision = resolveLote(selected: selected, destinations: destinations, eventoRoot: eventoRoot)
        let loteNumero = loteDecision?.numero
        // {contador}: numeração POR LOTE (reinicia a cada lote) quando a estrutura usa {lote}, com
        // continuação opt-in entre lotes. Sem {lote}, é uma sequência contínua única (posição no cartão).
        // A posição é sempre sobre TODA a mídia plana (independe da seleção foto/vídeo → estável).
        let countable = all.filter { !$0.preserve && ($0.type == .photo || $0.type == .video || $0.type == .audio) }
        var counterIndex: [String: Int] = [:]
        if let loteNumero {
            // mídia de OUTROS lotes não conta na posição deste lote → o novo material reinicia em 1.
            let outrosLotes = priorLoteMediaKeys(destinations: destinations, eventoRoot: eventoRoot, excludingLote: loteNumero)
            let offset = preset.rename.counterContinuesAcrossLotes ? outrosLotes.count : 0
            let doLote = countable.filter { !outrosLotes.contains(LoteFileKey(relPath: $0.relPath, bytes: $0.size)) }
            for (i, f) in doLote.enumerated() { counterIndex[f.relPath] = i + 1 + offset }
        } else {
            for (i, f) in countable.enumerated() { counterIndex[f.relPath] = i + 1 }
        }

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
                        acc.addVerified(.init(sourceRelPath: pv.sourceRel, destRelPath: pv.rel, type: pv.type, bytes: pv.bytes, xxhash64: pv.hashHex, status: "verified", sourceDate: pv.sourceDate), category: category)
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
                                 presentBySrcByDest: presentBySrcByDest,
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

        // segmento de pasta do lote pros bundles de cinema (que não passam pelo template): "Lote NN/" ou "".
        // posiciona o lote logo após o evento (cinema já é verbatim sob <evento>/<cartão>), então separa
        // os clipes de cinema por descarga igual aos arquivos planos. (loteNumero já resolvido acima.)
        let loteSeg = loteNumero.map { NameBuilder.loteLabel(for: locale) + " " + String(format: "%02d", $0) + "/" } ?? ""
        do {
            // 1) arquivos planos: achata + renomeia (contador por lote, resolvido acima)
            for file in selected where !file.preserve {
                let context = NamingContext(camera: cameraOf(file), counter: counterIndex[file.relPath] ?? 1,
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
            let fp = Self.offloadID(files: selected, cardID: cardID)
            let totals = Manifest.Totals(
                photos: selected.filter { $0.type == .photo }.count,
                videos: selected.filter { $0.type == .video }.count,
                audio: selected.filter { $0.type == .audio }.count,
                cinema: PreservePlanner.bundleCount(selected),
                sidecars: records.filter { $0.type == .sidecar }.count,
                verified: snap.verified, failed: snap.failures.count, skipped: skipped.count)
            var partialManifest = Manifest(
                schemaVersion: 2, offloadId: fp, appVersion: appVersion,
                presetName: preset.name, camera: manifestCamera, startedAt: started, finishedAt: clock(),
                source: .init(volumeName: cardRoot.lastPathComponent, fingerprint: fp, fileCount: selected.count, bytes: required, volumeID: cardID, mediaKind: sourceKind),
                destinations: destinations.map(\.path), files: records, unrecognized: unrecognized,
                totals: totals, interrupted: true, lote: loteNumero)
            partialManifest.projectName = eventoRoot
            partialManifest.failedPaths = snap.failures
            partialManifest.excludedByChoice = excludedByChoice
            partialManifest.keptCameras = keptCameras.isEmpty ? nil : keptCameras
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
        let fingerprint = Self.offloadID(files: selected, cardID: cardID)
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
                var destManifest = Manifest(
                    schemaVersion: 2, offloadId: fingerprint, appVersion: appVersion,
                    presetName: preset.name, camera: manifestCamera, startedAt: started, finishedAt: finished,
                    source: .init(volumeName: cardRoot.lastPathComponent, fingerprint: fingerprint, fileCount: selected.count, bytes: required, volumeID: cardID, mediaKind: sourceKind),
                    destinations: destinations.map(\.path),
                    files: destFiles, unrecognized: unrecognized, totals: destTotals, lote: loteNumero)
                destManifest.projectName = eventoRoot
                destManifest.failedPaths = failures
                destManifest.excludedByChoice = excludedByChoice
                destManifest.keptCameras = keptCameras.isEmpty ? nil : keptCameras
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
                              manifestFailures: manifestFailures, cameraFilesLeft: leftByCamera.count)
    }
}
