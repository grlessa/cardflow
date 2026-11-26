import Foundation
import AppKit
import OffloadKit

@MainActor @Observable
final class VolumeWatcher {
    var volumes: [ExternalVolume] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    var observerCount: Int { observers.count }

    func start() {
        guard observers.isEmpty else { return }
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        let nc = NSWorkspace.shared.notificationCenter
        for obs in observers { nc.removeObserver(obs) }
        observers.removeAll()
    }

    nonisolated deinit {
        let bag = ObserverBag(observers)
        if !bag.items.isEmpty {
            DispatchQueue.main.async {
                let nc = NSWorkspace.shared.notificationCenter
                for o in bag.items { nc.removeObserver(o) }
            }
        }
    }

    private final class ObserverBag: @unchecked Sendable {
        let items: [NSObjectProtocol]
        init(_ items: [NSObjectProtocol]) { self.items = items }
    }

    /// Enumera volumes e consulta DiskArbitration fora da thread principal (discos externos lentos ou
    /// volumes de rede sob `/Volumes/` não podem travar a interface).
    func refresh() {
        refreshGeneration &+= 1
        let gen = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task.detached { [weak self] in
            let found = Self.scanVolumes()
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == gen else { return }
                self.volumes = found
            }
        }
    }

    /// Versão síncrona (testes).
    func refreshNow() { volumes = Self.scanVolumes() }

    private nonisolated static func scanVolumes() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeIsEjectableKey, .volumeIsBrowsableKey,
                                      .volumeTotalCapacityKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            // só volumes montados em /Volumes (exclui o disco de sistema em "/")
            guard url.path.hasPrefix("/Volumes/") else { return nil }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true else { return nil }
            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
            return ExternalVolume(url: url, name: v.volumeName ?? url.lastPathComponent,
                                  isRemovable: removable, isInternal: v.volumeIsInternal ?? false,
                                  totalBytes: v.volumeTotalCapacity.map { Int64($0) },
                                  physicalDeviceID: PhysicalDisk.wholeDiskBSD(for: url),
                                  volumeUUID: v.allValues[.volumeUUIDStringKey] as? String,
                                  traits: PhysicalDisk.traits(for: url))
        }
    }
}
