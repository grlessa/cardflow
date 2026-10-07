import Foundation
import DiskArbitration

public enum PhysicalDisk {
    /// BSD do whole-disk de um volume (ex.: "disk4"), via DiskArbitration. Duas partições do MESMO
    /// disco físico devolvem o mesmo id → dá pra impedir "backup" no mesmo disco. `nil` se não der pra
    /// determinar (rede/sintético).
    public static func wholeDiskBSD(for url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let whole = DADiskCopyWholeDisk(disk),
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
    /// DiskArbitration não reconhecer o caminho (pasta comum, rede).
    public static func traits(for url: URL) -> DeviceTraits? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
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
