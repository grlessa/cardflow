import Foundation
import OffloadKit

/// Uma cópia registrada (um cartão num projeto), pra seção Recentes.
struct RecentOffload: Identifiable, Equatable {
    var id: String { manifest.offloadId }
    let manifest: Manifest
    /// JSON do registro no destino onde foi achado (relatório, pasta do projeto).
    let manifestURL: URL
    /// Total de bytes de mídia (fora de `.cardflow/`), pré-calculado para não reter arrays gigantes em RAM.
    let totalBytes: Int64

    var title: String { manifest.source.volumeName }
    var projectName: String { manifest.projectName ?? manifestURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
    var projectURL: URL { manifestURL.deletingLastPathComponent().deletingLastPathComponent() }
    var failed: Bool { manifest.totals.failed > 0 || !(manifest.failedPaths ?? []).isEmpty }
}

/// Recentes: cópias registradas nos destinos ativos, mais recente primeiro. Uma cópia gravada em dois
/// destinos (principal + backup) aparece uma vez.
@MainActor @Observable
final class HistoryStore {
    private(set) var items: [RecentOffload] = []
    nonisolated static let limit = 50

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Relê em segundo plano: abrir pasta pode esperar a permissão do macOS (Mesa, Documentos) ou um
    /// disco lento, e isso nunca pode travar a janela. Cancela varreduras anteriores sobrepostas.
    func reload(destinations: [URL]) {
        generation &+= 1
        let gen = generation
        scanTask?.cancel()
        scanTask = Task.detached {
            let found = Self.scan(destinations)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.items = found
            }
        }
    }

    /// Versão síncrona (testes).
    func reloadNow(destinations: [URL]) { items = Self.scan(destinations) }

    nonisolated static func scan(_ destinations: [URL]) -> [RecentOffload] {
        let store = ManifestStore()
        var all: [RecentOffload] = []
        let fm = FileManager.default
        for dest in destinations {
            if Task.isCancelled { return [] }
            guard let projects = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if Task.isCancelled { return [] }
                all += store.loadAllWithURLs(eventRootIn: dest, eventName: project.lastPathComponent)
                    .map { entry -> RecentOffload in
                        let mediaBytes = entry.manifest.files
                            .filter { !$0.destRelPath.contains("/.cardflow/") }
                            .reduce(Int64(0)) { $0 + $1.bytes }
                        var compact = entry.manifest
                        compact.files = []   // libera memória: Recentes usa só resumo e totais
                        return RecentOffload(manifest: compact, manifestURL: entry.url, totalBytes: mediaBytes)
                    }
            }
        }
        // mesmo offloadId (outro destino, ou retomada que reescreveu): fica o registro mais recente.
        var newest: [String: RecentOffload] = [:]
        for r in all where newest[r.id].map({ $0.manifest.finishedAt < r.manifest.finishedAt }) ?? true {
            newest[r.id] = r
        }
        return Array(newest.values.sorted { $0.manifest.finishedAt > $1.manifest.finishedAt }.prefix(limit))
    }

    func item(_ id: String) -> RecentOffload? { items.first { $0.id == id } }
}
