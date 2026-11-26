import Foundation
import DiskArbitration
import IOKit

public enum PhysicalDisk {
    /// Resolve a raiz do volume montado para qualquer caminho (inclusive subpastas ou caminhos que
    /// ainda não existem). `DADiskCreateFromVolumePath` falha em subpastas, então normalizamos antes.
    private static func volumeRoot(for url: URL) -> URL {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return (try? dir.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? dir
    }

    /// Sobe o IOKit de um contêiner APFS sintetizado até o disco físico `IOMedia` subjacente, para que
    /// uma partição APFS e uma exFAT no mesmo SSD devolvam o mesmo identificador físico.
    private static func backingPhysicalWholeDiskBSD(of disk: DADisk) -> String? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var visited: Set<UInt64> = []
        var stack: [io_registry_entry_t] = []
        IOObjectRetain(media)
        stack.append(media)
        var candidates: [String] = []
        while let entry = stack.popLast() {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS {
                if !visited.insert(id).inserted { continue }
            }
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               IOObjectConformsTo(entry, "AppleAPFSContainerScheme") == 0,
               let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
               whole,
               let bsd = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                // Ignora discos sintetizados (Content == APFS Container Scheme GUID)
                let content = (IORegistryEntryCreateCFProperty(entry, "Content" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
                if content.caseInsensitiveCompare("EF57347C-0000-11AA-AA11-00306543ECAC") != .orderedSame {
                    candidates.append(bsd)
                }
            }
            var iter: io_iterator_t = 0
            if IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iter) == KERN_SUCCESS {
                defer { IOObjectRelease(iter) }
                while true {
                    let parent = IOIteratorNext(iter)
                    if parent == 0 { break }
                    stack.append(parent)
                }
            }
        }
        return candidates.sorted().first
    }

    /// BSD do whole-disk de um volume ou subpasta (ex.: "disk4"), via DiskArbitration. Duas partições
    /// do MESMO disco físico devolvem o mesmo id -> dá pra impedir "backup" no mesmo disco. `nil` se
    /// não der pra determinar (rede/sintético).
    public static func wholeDiskBSD(for url: URL) -> String? {
        let root = volumeRoot(for: url)
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, root as CFURL) else { return nil }
        if let physical = backingPhysicalWholeDiskBSD(of: disk) { return physical }
        guard let whole = DADiskCopyWholeDisk(disk),
              let bsd = DADiskGetBSDName(whole) else { return nil }
        return String(cString: bsd)
    }

    /// Tamanho em bytes do disco INTEIRO (ex.: "disk4"), via DiskArbitration. nil se não der pra ler.
    public static func wholeDiskSize(bsdName: String) -> UInt64? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any],
              let size = desc[kDADiskDescriptionMediaSizeKey] as? NSNumber else { return nil }
        return size.uint64Value
    }

    /// Tipo físico do dispositivo de um volume montado (leitor SD, USB, imagem de disco…). nil se o
    /// DiskArbitration não reconhecer o caminho (rede).
    public static func traits(for url: URL) -> DeviceTraits? {
        let root = volumeRoot(for: url)
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, root as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return nil }
        func str(_ k: CFString) -> String? {
            (desc[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return DeviceTraits(protocolName: str(kDADiskDescriptionDeviceProtocolKey),
                            deviceModel: str(kDADiskDescriptionDeviceModelKey),
                            mediaName: str(kDADiskDescriptionMediaNameKey),
                            isRemovableMedia: (desc[kDADiskDescriptionMediaRemovableKey] as? Bool) ?? false,
                            isInternalDevice: (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? false,
                            fileSystem: str(kDADiskDescriptionVolumeKindKey))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
