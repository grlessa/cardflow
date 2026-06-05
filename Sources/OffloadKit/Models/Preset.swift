import Foundation

public struct Preset: Codable, Equatable, Sendable {
    public struct Media: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case open, locked }
        public enum Kind: String, Codable, Sendable { case photo, video, audio, both }   // both = "Tudo" (inclui áudio)
        public var mode: Mode
        public var lockedTo: Kind
        public init(mode: Mode, lockedTo: Kind) {
            self.mode = mode; self.lockedTo = lockedTo
        }
    }

    public struct Rename: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var template: String
        public var counterPadding: Int
        public var counterStart: Int
        public var counterStep: Int
        public init(enabled: Bool, template: String, counterPadding: Int, counterStart: Int = 1, counterStep: Int = 1) {
            self.enabled = enabled; self.template = template; self.counterPadding = counterPadding
            self.counterStart = counterStart; self.counterStep = counterStep
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            template = try c.decode(String.self, forKey: .template)
            counterPadding = try c.decode(Int.self, forKey: .counterPadding)
            counterStart = try c.decodeIfPresent(Int.self, forKey: .counterStart) ?? 1
            counterStep = try c.decodeIfPresent(Int.self, forKey: .counterStep) ?? 1
        }
    }

    public struct SessionField: Codable, Equatable, Sendable {
        public var key: String
        public var label: String
        public init(key: String, label: String) { self.key = key; self.label = label }
    }

    public enum SidecarPolicy: String, Codable, Sendable { case aside, skip }

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var evento: String
    public var media: Media
    public var rename: Rename
    public var destinationRoles: [String]
    public var folderStructure: String
    public var photoExtensions: [String]
    public var videoExtensions: [String]
    public var audioExtensions: [String]
    public var sidecarExtensions: [String]
    public var copySidecars: SidecarPolicy
    public var dateFormat: String
    public var timeFormat: String   // formato do token {hora} (ex.: "HHmmss", "HH'h'mm")
    public var locale: String
    public var sessionFields: [SessionField]

    public init(
        schemaVersion: Int = 2, id: String, name: String, evento: String,
        media: Media, rename: Rename, destinationRoles: [String], folderStructure: String,
        photoExtensions: [String], videoExtensions: [String], audioExtensions: [String],
        sidecarExtensions: [String], copySidecars: SidecarPolicy, dateFormat: String,
        timeFormat: String = "HHmmss",
        locale: String = "pt_BR", sessionFields: [SessionField] = []
    ) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.evento = evento
        self.media = media; self.rename = rename; self.destinationRoles = destinationRoles
        self.folderStructure = folderStructure; self.photoExtensions = photoExtensions
        self.videoExtensions = videoExtensions; self.audioExtensions = audioExtensions
        self.sidecarExtensions = sidecarExtensions; self.copySidecars = copySidecars
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.locale = locale
        self.sessionFields = sessionFields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        evento = try c.decode(String.self, forKey: .evento)
        media = try c.decode(Media.self, forKey: .media)
        rename = try c.decode(Rename.self, forKey: .rename)
        destinationRoles = try c.decode([String].self, forKey: .destinationRoles)
        folderStructure = try c.decode(String.self, forKey: .folderStructure)
        photoExtensions = try c.decode([String].self, forKey: .photoExtensions)
        videoExtensions = try c.decode([String].self, forKey: .videoExtensions)
        audioExtensions = try c.decode([String].self, forKey: .audioExtensions)
        sidecarExtensions = try c.decode([String].self, forKey: .sidecarExtensions)
        copySidecars = try c.decode(SidecarPolicy.self, forKey: .copySidecars)
        dateFormat = try c.decode(String.self, forKey: .dateFormat)
        timeFormat = try c.decodeIfPresent(String.self, forKey: .timeFormat) ?? "HHmmss"   // compat: preset antigo
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "pt_BR"
        sessionFields = try c.decodeIfPresent([SessionField].self, forKey: .sessionFields) ?? []
    }
}

extension Preset {
    /// Preset de exemplo usado nos testes.
    public static var sampleConferencia: Preset {
        Preset(
            id: "abc", name: "Conferência Junho 2026", evento: "Conferencia-Junho-2026",
            media: .init(mode: .open, lockedTo: .both),
            rename: .init(enabled: false, template: "{evento}_{camera}_{data}_{hora}_{nome_original}", counterPadding: 4),
            destinationRoles: ["Cópia", "Backup"], folderStructure: "{evento}/{tipo}",
            photoExtensions: ["jpg", "jpeg", "heic", "heif", "arw", "cr2", "cr3", "raf", "rw2", "dng", "nef", "orf"],
            videoExtensions: ["mp4", "mov"], audioExtensions: [],
            sidecarExtensions: ["xml", "thm", "xmp", "bim", "cube"], copySidecars: .aside,
            dateFormat: "yyyy-MM-dd"
        )
    }

    /// Cópia com novo `id` e `name` (pra duplicar/importar sem colidir).
    public func duplicated(newName: String) -> Preset {
        var p = self
        p.id = UUID().uuidString
        p.name = newName
        return p
    }
}
