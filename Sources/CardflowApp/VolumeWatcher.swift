import Foundation
import AppKit
import OffloadKit

@MainActor @Observable
final class VolumeWatcher {
    var volumes: [ExternalVolume] = []
    private var observers: [NSObjectProtocol] = []
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

    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsBrowsableKey, .volumeTotalCapacityKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            // só volumes montados em /Volumes (exclui o disco de sistema em "/")
            guard url.path.hasPrefix("/Volumes/") else { return nil }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true else { return nil }
            let removable = (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false)
            return ExternalVolume(url: url, name: v.volumeName ?? url.lastPathComponent,
                                  isRemovable: removable, isInternal: v.volumeIsInternal ?? false,
                                  totalBytes: v.volumeTotalCapacity.map { Int64($0) },
                                  physicalDeviceID: PhysicalDisk.wholeDiskBSD(for: url),
                                  volumeUUID: v.allValues[.volumeUUIDStringKey] as? String)
        }
    }
}
