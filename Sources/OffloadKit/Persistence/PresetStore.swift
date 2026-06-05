import Foundation

extension Preset {
    /// Preset de fábrica neutro, sempre disponível (usado quando nada foi configurado).
    public static var factoryDefault: Preset {
        Preset(
            schemaVersion: 2, id: "factory-default", name: "Padrão", evento: "Sessão",
            media: .init(mode: .open, lockedTo: .both),
            rename: .init(enabled: false,
                          template: "{evento}_{data}_{hora}_{nome_original}",   // Data/Hora consolidados (menos peças)
                          counterPadding: 4),
            destinationRoles: ["Cópia"], folderStructure: "{evento}/{dia} {mes_abrev} {ano}/{tipo}",
            photoExtensions: ["jpg", "jpeg", "heic", "heif", "hif", "arw", "cr2", "cr3", "crw", "raf",
                              "rw2", "rwl", "dng", "nef", "nrw", "orf", "gpr", "tif", "tiff", "insp"],
            videoExtensions: ["mp4", "mov", "mts", "m2ts", "avi", "insv", "360", "3gp"],
            audioExtensions: ["wav", "mp3", "m4a", "aac", "flac", "aiff", "aif"],
            // sidecars desligados por padrão: a maioria não usa os XMLs de metadados e eles
            // inflavam a contagem (106 vídeos viravam 211 arquivos). Dá pra religar no editor.
            sidecarExtensions: ["xml", "thm", "xmp", "bim", "cube"], copySidecars: .skip,
            dateFormat: "yyyy-MM-dd", locale: "pt_BR", sessionFields: []
        )
    }

    /// Fixture neutro (evento "Offload", estrutura plana) — usado por testes que fixam caminho exato,
    /// pra ficarem determinísticos independente do default do usuário.
    public static var flatDefault: Preset {
        Preset(
            schemaVersion: 2, id: "flat-default", name: "Plano", evento: "Offload",
            media: .init(mode: .open, lockedTo: .both),
            rename: .init(enabled: false,
                          template: "{evento}_{ano}{mes}{dia}_{horas}{minutos}{segundos}_{nome_original}",
                          counterPadding: 4),
            destinationRoles: ["Cópia"], folderStructure: "{evento}/{tipo}",
            photoExtensions: ["jpg", "jpeg", "heic", "heif", "hif", "arw", "cr2", "cr3", "raf",
                              "rw2", "rwl", "dng", "nef", "nrw", "orf", "gpr", "tif", "tiff"],
            videoExtensions: ["mp4", "mov", "mts", "m2ts", "avi"],
            audioExtensions: ["wav", "mp3", "m4a", "aac", "flac", "aiff", "aif"],
            sidecarExtensions: ["xml", "thm", "xmp", "bim", "cube"], copySidecars: .aside,
            dateFormat: "yyyy-MM-dd", locale: "pt_BR", sessionFields: []
        )
    }
}

public struct PresetStore {
    public enum PresetError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidTemplate(String)
    }

    public static let maxSchemaVersion = 2

    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func appPresetsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Cardflow/presets", isDirectory: true)
    }

    /// Valida schema suportado + tokens conhecidos nos templates (estrutura e renome).
    public static func validate(_ preset: Preset) throws {
        guard (1...maxSchemaVersion).contains(preset.schemaVersion) else {
            throw PresetError.unsupportedSchema(preset.schemaVersion)   // rejeita 0/negativo também
        }
        guard !preset.folderStructure.isEmpty else { throw PresetError.invalidTemplate("estrutura de pastas vazia") }
        guard preset.rename.counterPadding >= 1 else { throw PresetError.invalidTemplate("contador inválido (< 1 dígito)") }
        // o id vira o nome do arquivo .cfp em disco — não pode conter separador nem travessia.
        let id = preset.id
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains(":"),
              !id.contains(".."), !id.hasPrefix("~"), !id.contains("\0") else {
            throw PresetError.invalidTemplate("identificador de preset inválido")
        }
        let keys = Set(preset.sessionFields.map(\.key))
        do {
            // traversal primeiro (defesa contra preset não confiável), depois tokens conhecidos.
            try NameBuilder.validateNoTraversal(in: preset.folderStructure)
            try NameBuilder.validateTokensExist(in: preset.folderStructure, knownSessionKeys: keys)
            // o template de nome só é usado (e cobrado) quando o renome está ligado.
            if preset.rename.enabled {
                try NameBuilder.validateNoTraversal(in: preset.rename.template)
                try NameBuilder.validateTokensExist(in: preset.rename.template, knownSessionKeys: keys)
            }
        } catch let e as NamingError {
            throw PresetError.invalidTemplate(e.errorDescription ?? "\(e)")
        }
    }

    @discardableResult
    public func save(_ preset: Preset) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(preset.id).cfp")
        try export(preset, to: url)
        return url
    }

    public func export(_ preset: Preset, to url: URL) throws {
        try Self.validate(preset)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(preset).write(to: url)
    }

    public func load(from url: URL) throws -> Preset {
        let preset = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
        try Self.validate(preset)
        return preset
    }

    public func list() throws -> [Preset] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "cfp" }
            .compactMap { try? load(from: $0) }
            .sorted { $0.name < $1.name }
    }

    public func delete(id: String) throws {
        let url = directory.appendingPathComponent("\(id).cfp")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

extension PresetStore.PresetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v):
            return "Este preset foi feito numa versão incompatível do app (schema \(v))."
        case .invalidTemplate(let reason):
            return "Preset inválido: \(reason)"
        }
    }
}
