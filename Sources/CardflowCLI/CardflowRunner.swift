import Foundation
import OffloadKit

public enum CardflowRunError: Error, Equatable {
    case noSpace
    case verificationFailed(Int)
    case sameDisk([String])
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
            output("Abortado: destinos no mesmo disco físico (\(dup.joined(separator: ", "))) — o backup precisa ser outro disco.")
            throw CardflowRunError.sameDisk(dup)
        }
        let service = CopyService(preset: preset, spaceProvider: VolumeFreeSpace())

        let preview = try service.preview(cardRoot: card, chosenMedia: config.media, destinations: destinations)
        output(Report.summary(preview: preview, destinations: destinations))

        if !preview.shortfalls.isEmpty {
            output("Abortado: espaço insuficiente.")
            throw CardflowRunError.noSpace
        }
        if config.dryRun {
            output("(dry-run) Nada foi copiado.")
            return
        }
        if !config.assumeYes {
            let answer = (input("Confirmar cópia? [s/N] ") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard answer == "s" || answer == "sim" || answer == "y" else {
                output("Cancelado pelo usuário.")
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
