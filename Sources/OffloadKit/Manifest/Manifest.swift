import Foundation

public struct Manifest: Codable, Equatable, Sendable {
    public struct FileRecord: Codable, Equatable, Sendable {
        public var sourceRelPath: String
        public var destRelPath: String
        public var type: FileType
        public var bytes: Int64
        public var xxhash64: String
        public var status: String   // "verified" | "present"
        public init(sourceRelPath: String, destRelPath: String, type: FileType, bytes: Int64, xxhash64: String, status: String) {
            self.sourceRelPath = sourceRelPath; self.destRelPath = destRelPath; self.type = type
            self.bytes = bytes; self.xxhash64 = xxhash64; self.status = status
        }
    }
    public struct SourceInfo: Codable, Equatable, Sendable {
        public var volumeName: String
        public var fingerprint: String
        public var fileCount: Int
        public var bytes: Int64
        public init(volumeName: String, fingerprint: String, fileCount: Int, bytes: Int64) {
            self.volumeName = volumeName; self.fingerprint = fingerprint; self.fileCount = fileCount; self.bytes = bytes
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

    public init(schemaVersion: Int, offloadId: String, appVersion: String, presetName: String, camera: String,
                startedAt: Date, finishedAt: Date, source: SourceInfo, destinations: [String],
                files: [FileRecord], unrecognized: [String], totals: Totals, interrupted: Bool = false) {
        self.schemaVersion = schemaVersion; self.offloadId = offloadId; self.appVersion = appVersion
        self.presetName = presetName; self.camera = camera; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.source = source; self.destinations = destinations; self.files = files
        self.unrecognized = unrecognized; self.totals = totals; self.interrupted = interrupted
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
    }
}
