import Foundation
import OffloadKit

public enum CardflowRunError: Error, Equatable {
    case noSpace
    case verificationFailed(Int)
    case sameDisk([String])
}

public enum CardflowHelp {
    /// Texto de ajuda (--help) localizado. Mora aqui (e não no main.swift do executável)
    /// porque o catálogo de strings está no bundle `.module` do target CardflowCLI.
    public static var text: String { CLIStrings.string("cli.help") }
}

public enum CardflowRunner {
    /// Constrói o preset (default ou de --preset) aplicando overrides de evento/rename.
    static func buildPreset(_ config: CardflowConfig) throws -> Preset {
        var preset: Preset
        if let path = config.presetPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            preset = try JSONDecoder().decode(Preset.self, from: data)
            if let e = config.evento { preset.evento = e }   // só sobrescreve se --evento foi passado
        } else {
            preset = .factoryDefault
            if let e = config.evento { preset.evento = e }    // sem preset: usa o de fábrica (evento "Sessão")
        }
        if config.renameOverride == true { preset.rename.enabled = true }
        try PresetStore.validate(preset)                       // schema + tokens, antes de qualquer cópia
        return preset
    }

    public static func run(_ config: CardflowConfig,
                           input: (String) -> String?,
                           output: (String) -> Void) throws {
        let preset = try buildPreset(config)
        let card = URL(fileURLWithPath: config.card)
        let destinations = config.destinations.map { URL(fileURLWithPath: $0) }
        // destinos no MESMO disco físico → "backup" não é redundância (o app já bloqueia isso).
        var byDisk: [String: [String]] = [:]
        for url in destinations {
            if let bsd = PhysicalDisk.wholeDiskBSD(for: url) { byDisk[bsd, default: []].append(url.lastPathComponent) }
        }
        if let dup = byDisk.values.first(where: { $0.count > 1 }) {
            output(CLIStrings.string("cli.abort.sameDisk %@", dup.joined(separator: ", ")))
            throw CardflowRunError.sameDisk(dup)
        }
        let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace(), locale: CLIStrings.effectiveLocale)

        let preview = try service.preview(cardRoot: card, chosenMedia: config.media, destinations: destinations)
        output(Report.summary(preview: preview, destinations: destinations))

        if !preview.shortfalls.isEmpty {
            output(CLIStrings.string("cli.abort.noSpace"))
            throw CardflowRunError.noSpace
        }
        if config.dryRun {
            output(CLIStrings.string("cli.dryRun.nothingCopied"))
            return
        }
        if !config.assumeYes {
            let prompt = CLIStrings.string("cli.confirm.prompt")
            let answer = (input(prompt) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard answer == "s" || answer == "sim" || answer == "y" else {
                output(CLIStrings.string("cli.cancelled"))
                return
            }
        }

        let outcome = try service.run(cardRoot: card, chosenMedia: config.media,
                                      destinations: destinations, camera: config.camera,
                                      sessionValues: config.sessionValues)
        output(Report.outcome(outcome))
        let verdict = Report.verdict(outcome)
        output(verdict.line)
        if !verdict.ok { throw CardflowRunError.verificationFailed(outcome.failures.count) }
    }
}
