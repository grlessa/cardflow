import Foundation
import OffloadKit

public struct CardflowConfig: Equatable {
    public var card: String
    public var destinations: [String]
    public var media: Preset.Media.Kind
    public var camera: String
    public var evento: String?          // nil = não passou --evento (usa o do preset)
    public var renameOverride: Bool?    // nil = não passou --rename (usa o do preset)
    public var dryRun: Bool
    public var assumeYes: Bool
    public var presetPath: String?
    public var sessionValues: [String: String] = [:]
}

public enum CLIError: Error, Equatable {
    case missing(String)
    case badValue(String)
}

public enum ArgParser {
    /// Remove os args de NSGlobalDomain que o macOS injeta em argv (ex.: `-AppleLanguages "(en)"`,
    /// `-AppleLocale "en"`). O runtime já os leu pra resolver `Locale.preferredLanguages`; aqui só
    /// evitamos que o parser da CLI trate a flag como argumento inválido. Tira a flag E o valor.
    public static func dropSystemDefaultsArgs(_ args: [String]) -> [String] {
        let systemFlags: Set<String> = ["-AppleLanguages", "-AppleLocale", "-AppleTextDirection"]
        var out: [String] = []
        var i = 0
        while i < args.count {
            if systemFlags.contains(args[i]) {
                i += 2   // pula a flag e o valor (ex.: "(en)")
                continue
            }
            out.append(args[i])
            i += 1
        }
        return out
    }

    public static func parse(_ args: [String]) throws -> CardflowConfig {
        var card: String?
        var destinations: [String] = []
        var media: Preset.Media.Kind = .both
        var camera = "Cam"
        var evento: String? = nil
        var renameOverride: Bool? = nil
        var dryRun = false
        var assumeYes = false
        var presetPath: String?
        var sessionValues: [String: String] = [:]

        var i = 0
        func nextValue(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw CLIError.missing(flag) }
            return args[i]
        }

        while i < args.count {
            switch args[i] {
            case "--card": card = try nextValue("--card")
            case "--to": destinations.append(try nextValue("--to"))
            case "--media":
                let v = try nextValue("--media")
                switch v {
                case "both", "ambos", "tudo": media = .both
                case "foto", "photo": media = .photo
                case "video", "vídeo": media = .video
                case "audio", "áudio": media = .audio
                default: throw CLIError.badValue("--media \(v)")
                }
            case "--camera": camera = try nextValue("--camera")
            case "--evento": evento = try nextValue("--evento")
            case "--preset": presetPath = try nextValue("--preset")
            case "--set":
                let kv = try nextValue("--set")
                guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { throw CLIError.badValue("--set \(kv)") }
                let key = String(kv[..<eq]); let value = String(kv[kv.index(after: eq)...])
                sessionValues[key] = value
            case "--rename": renameOverride = true
            case "--dry-run": dryRun = true
            case "--yes", "-y": assumeYes = true
            default: throw CLIError.badValue(args[i])
            }
            i += 1
        }

        guard let card else { throw CLIError.missing("--card") }
        guard !destinations.isEmpty else { throw CLIError.missing("--to") }
        return CardflowConfig(card: card, destinations: destinations, media: media,
                              camera: camera, evento: evento, renameOverride: renameOverride,
                              dryRun: dryRun, assumeYes: assumeYes, presetPath: presetPath,
                              sessionValues: sessionValues)
    }
}
