import Foundation

public struct Manifest: Codable, Equatable, Sendable {
    public struct FileRecord: Codable, Equatable, Sendable {
        public var sourceRelPath: String
        public var destRelPath: String
        public var type: FileType
        public var bytes: Int64
        public var xxhash64: String
        public var status: String   // "verified" | "present"
        /// Data do arquivo no cartão (a mesma `captureDate` do scanner). Junto com caminho e tamanho,
        /// identifica o arquivo de origem sem reler: dois cartões com `DSC00001.ARW` do mesmo tamanho
        /// (RAW sem compressão tem tamanho fixo) não se confundem. nil em manifesto de versão antiga.
        public var sourceDate: Date?
        public init(sourceRelPath: String, destRelPath: String, type: FileType, bytes: Int64, xxhash64: String,
                    status: String, sourceDate: Date? = nil) {
            self.sourceRelPath = sourceRelPath; self.destRelPath = destRelPath; self.type = type
            self.bytes = bytes; self.xxhash64 = xxhash64; self.status = status; self.sourceDate = sourceDate
        }

        /// Este registro descreve o arquivo `file` do cartão (o caminho já casou)? Tamanho tem que bater;
        /// a data, quando o registro tem, também (tolerância de 1 s: o ISO 8601 do manifesto corta a
        /// fração). nil = manifesto antigo sem data, indeterminado: quem chama decide (conferir o hash).
        public func matchesSource(size: Int64, date: Date) -> Bool? {
            guard bytes == size else { return false }
            guard let sourceDate else { return nil }
            return abs(sourceDate.timeIntervalSince(date)) <= 1
        }
    }
    public struct SourceInfo: Codable, Equatable, Sendable {
        public var volumeName: String
        public var fingerprint: String
        public var fileCount: Int
        public var bytes: Int64
        /// Identidade do volume do cartão (número de série que ele ganha ao ser formatado). Dois cartões com
        /// os mesmos arquivos nunca se confundem. nil em registro antigo ou quando a origem é uma pasta.
        public var volumeID: String?
        /// Tipo do dispositivo (`MediaKind.rawValue`), pro ícone do relatório. nil em registro antigo.
        public var mediaKind: String?
        public init(volumeName: String, fingerprint: String, fileCount: Int, bytes: Int64, volumeID: String? = nil,
                    mediaKind: String? = nil) {
            self.volumeName = volumeName; self.fingerprint = fingerprint; self.fileCount = fileCount; self.bytes = bytes
            self.volumeID = volumeID; self.mediaKind = mediaKind
        }
    }
    public struct Totals: Codable, Equatable, Sendable {
        public var photos: Int, videos: Int, audio: Int, cinema: Int, sidecars: Int, verified: Int, failed: Int, skipped: Int
        public init(photos: Int, videos: Int, audio: Int, cinema: Int = 0, sidecars: Int, verified: Int, failed: Int, skipped: Int) {
            self.photos = photos; self.videos = videos; self.audio = audio; self.cinema = cinema
            self.sidecars = sidecars; self.verified = verified; self.failed = failed; self.skipped = skipped
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            photos = try c.decode(Int.self, forKey: .photos)
            videos = try c.decode(Int.self, forKey: .videos)
            audio = try c.decode(Int.self, forKey: .audio)
            cinema = try c.decodeIfPresent(Int.self, forKey: .cinema) ?? 0
            sidecars = try c.decode(Int.self, forKey: .sidecars)
            verified = try c.decode(Int.self, forKey: .verified)
            failed = try c.decode(Int.self, forKey: .failed)
            skipped = try c.decode(Int.self, forKey: .skipped)
        }
    }
    public var schemaVersion: Int
    public var offloadId: String
    public var appVersion: String
    public var presetName: String
    public var camera: String
    public var startedAt: Date
    public var finishedAt: Date
    public var source: SourceInfo
    public var destinations: [String]
    public var files: [FileRecord]
    public var unrecognized: [String]
    public var totals: Totals
    /// true quando o offload foi cortado no meio (crash/quit/cabo): o manifesto é um registro
    /// PARCIAL do que já tinha sido salvo e conferido até a interrupção, não de um backup completo.
    public var interrupted: Bool
    /// Número do lote (descarga) deste offload. nil em manifesto antigo ou sem o token {lote}.
    public var lote: Int?
    /// Preenchido quando o Cardflow formatou o cartão desta descarga (histórico). nil = não formatou aqui.
    public var cardFormatted: CardFormatRecord?
    /// Nome da pasta do projeto (raiz no destino). nil em manifesto antigo.
    public var projectName: String?
    /// Caminhos (no cartão) dos arquivos que não passaram na conferência. nil em manifesto antigo.
    public var failedPaths: [String]?
    /// Mídia que ficou no cartão por escolha (tipo de mídia, filtro de data). nil em manifesto antigo.
    public var excludedByChoice: [String]?
    /// Câmeras deixadas no cartão de propósito (material de outra pessoa): o cartão não pode ser formatado.
    public var keptCameras: [String]?

    public init(schemaVersion: Int, offloadId: String, appVersion: String, presetName: String, camera: String,
                startedAt: Date, finishedAt: Date, source: SourceInfo, destinations: [String],
                files: [FileRecord], unrecognized: [String], totals: Totals, interrupted: Bool = false,
                lote: Int? = nil) {
        self.schemaVersion = schemaVersion; self.offloadId = offloadId; self.appVersion = appVersion
        self.presetName = presetName; self.camera = camera; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.source = source; self.destinations = destinations; self.files = files
        self.unrecognized = unrecognized; self.totals = totals; self.interrupted = interrupted
        self.lote = lote
    }

    // decode tolerante: manifestos gravados antes deste campo (sem `interrupted`) ainda carregam.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        offloadId = try c.decode(String.self, forKey: .offloadId)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        presetName = try c.decode(String.self, forKey: .presetName)
        camera = try c.decode(String.self, forKey: .camera)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        source = try c.decode(SourceInfo.self, forKey: .source)
        destinations = try c.decode([String].self, forKey: .destinations)
        files = try c.decode([FileRecord].self, forKey: .files)
        unrecognized = try c.decode([String].self, forKey: .unrecognized)
        totals = try c.decode(Totals.self, forKey: .totals)
        interrupted = try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
        lote = try c.decodeIfPresent(Int.self, forKey: .lote)
        cardFormatted = try c.decodeIfPresent(CardFormatRecord.self, forKey: .cardFormatted)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        failedPaths = try c.decodeIfPresent([String].self, forKey: .failedPaths)
        excludedByChoice = try c.decodeIfPresent([String].self, forKey: .excludedByChoice)
        keptCameras = try c.decodeIfPresent([String].self, forKey: .keptCameras)
    }
}

/// Registro de que o cartão de uma descarga foi formatado pelo Cardflow.
public struct CardFormatRecord: Codable, Equatable, Sendable {
    public var at: Date
    public var fileSystem: String
    public var clusterBytes: Int
    public var label: String
    public init(at: Date, fileSystem: String, clusterBytes: Int, label: String) {
        self.at = at; self.fileSystem = fileSystem; self.clusterBytes = clusterBytes; self.label = label
    }
}
