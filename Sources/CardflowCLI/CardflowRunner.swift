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
            let url = URL(fileURLWithPath: path)
            preset = try PresetStore(directory: url.deletingLastPathComponent()).load(from: url)
            if let e = config.evento { preset.evento = e }   // só sobrescreve se --projeto/--evento foi passado
        } else {
            preset = .factoryDefault
            if let e = config.evento { preset.evento = e }    // sem preset: usa o de fábrica (projeto "Projeto")
        }
        if config.renameOverride == true { preset.rename.enabled = true }
        try PresetStore.validate(preset)                       // schema + tokens, antes de qualquer cópia
        return preset
    }

    public static func run(_ config: CardflowConfig,
                           input: (String) -> String?,
                           output: (String) -> Void,
                           onProgress: ((OffloadProgress) -> Void)? = nil) throws {
        let preset = try buildPreset(config)
        let card = URL(fileURLWithPath: config.card)
        let destinations = config.destinations.map { URL(fileURLWithPath: $0) }
        // destinos no MESMO disco físico -> "backup" não é redundância (o app já bloqueia isso).
        var byDisk: [String: [String]] = [:]
        for url in destinations {
            if let bsd = PhysicalDisk.wholeDiskBSD(for: url) { byDisk[bsd, default: []].append(url.lastPathComponent) }
        }
        if let dup = byDisk.values.first(where: { $0.count > 1 }) {
            throw CardflowRunError.sameDisk(dup)
        }
        let internalDests = Set(destinations.filter { url in
            (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == true
        })
        let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace(), locale: CLIStrings.effectiveLocale)

        let preview = try service.preview(cardRoot: card, chosenMedia: config.media, destinations: destinations,
                                          capturedIn: config.capturedIn,
                                          internalDestinations: internalDests)
        output(Report.summary(preview: preview, destinations: destinations))

        if !preview.shortfalls.isEmpty {
            throw CardflowRunError.noSpace
        }
        if config.dryRun {
            output(CLIStrings.string("cli.dryRun.nothingCopied"))
            return
        }
        if !config.assumeYes {
            let prompt = CLIStrings.string("cli.confirm.prompt")
            let answer = (input(prompt) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let accepted: Set<String> = ["s", "sim", "y", "yes", "si", "sí"]
            guard accepted.contains(answer) else {
                output(CLIStrings.string("cli.cancelled"))
                return
            }
        }

        let outcome = try service.run(cardRoot: card, chosenMedia: config.media,
                                      destinations: destinations, camera: config.camera,
                                      sessionValues: config.sessionValues,
                                      capturedIn: config.capturedIn,
                                      fastResume: !config.verifyAll,
                                      internalDestinations: internalDests,
                                      onProgress: onProgress ?? { _ in })
        output(Report.outcome(outcome))
        let verdict = Report.verdict(outcome)
        output(verdict.line)
        if !verdict.ok { throw CardflowRunError.verificationFailed(outcome.failures.count) }
    }
}
