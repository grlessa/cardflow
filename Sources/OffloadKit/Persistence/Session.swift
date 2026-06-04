import Foundation

public struct DiskBinding: Codable, Equatable, Sendable {
    public var volumeUUID: String?
    public var lastKnownPath: String
    public init(volumeUUID: String?, lastKnownPath: String) {
        self.volumeUUID = volumeUUID; self.lastKnownPath = lastKnownPath
    }
}

public extension DiskBinding {
    /// URL do volume montado AGORA que casa este binding: por `volumeUUID` (estável) e, na falta, pelo
    /// `lastKnownPath`. `nil` se o disco não está plugado.
    func resolve(in volumes: [ExternalVolume]) -> URL? {
        if let uuid = volumeUUID, !uuid.isEmpty {
            return volumes.first(where: { $0.volumeUUID == uuid })?.url
        }
        // sem UUID salvo: casa por path SÓ se o volume nesse path também não tem UUID — pra um disco
        // DIFERENTE que reusou o mount path (/Volumes/Backup) não ser restaurado por engano.
        return volumes.first(where: { $0.url.path == lastKnownPath && ($0.volumeUUID ?? "").isEmpty })?.url
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var activePresetId: String?
    public var destinationBindings: [String: DiskBinding]   // papel de destino -> disco
    public var sessionValues: [String: String]              // camera, operador, etc.
    public var lastMediaChoice: String                       // "photo" | "video" | "both"
    public init(activePresetId: String? = nil, destinationBindings: [String: DiskBinding] = [:],
                sessionValues: [String: String] = [:], lastMediaChoice: String = "both") {
        self.activePresetId = activePresetId
        self.destinationBindings = destinationBindings
        self.sessionValues = sessionValues
        self.lastMediaChoice = lastMediaChoice
    }
}

public struct SessionStore {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func appSessionFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Cardflow/session.json")
    }

    public func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(session).write(to: fileURL)
    }
}
