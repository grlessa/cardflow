import Foundation
import CardFormatKit

/// Operações de sistema que a formatação usa. Real no helper (DiskArbitration, /dev/rdiskN, processos);
/// falso nos testes (arquivo-imagem).
public protocol DiskSystem {
    func describe(bsdName: String) throws -> DiskDescription
    func claim(bsdName: String) throws
    func unclaim(bsdName: String)
    func unmountWhole(bsdName: String) throws
    func remountWhole(bsdName: String)               // devolve o cartão ao Finder quando a formatação desiste
    func suppressAutomount(bsdName: String)          // dissente montagens do disco durante o job
    func restoreAutomount()                          // idempotente
    func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice
    func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String   // ex.: "disk4s1"
    func waitForSlice(bsdName: String, slice: Int, expectedStartSector: UInt64?, expectedSectorCount: UInt64?, timeout: TimeInterval) throws -> String
    func unmount(bsdName: String) throws                                                   // fatia
    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String)
    func mount(bsdName: String) throws
    func invalidate()
}

public extension DiskSystem {
    func claim(bsdName: String) throws {}
    func unclaim(bsdName: String) {}
    func waitForSlice(bsdName: String, slice: Int, expectedStartSector: UInt64?, expectedSectorCount: UInt64?, timeout: TimeInterval) throws -> String {
        try waitForSlice(bsdName: bsdName, slice: slice, timeout: timeout)
    }
    func invalidate() {}
}
