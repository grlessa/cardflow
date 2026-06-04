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
}
