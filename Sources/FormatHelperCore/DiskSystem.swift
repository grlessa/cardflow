import Foundation
import CardFormatKit

/// Operações de sistema que a formatação usa. Real no helper (DiskArbitration, /dev/rdiskN, processos);
/// falso nos testes (arquivo-imagem).
public protocol DiskSystem {
    func describe(bsdName: String) throws -> DiskDescription
    func unmountWhole(bsdName: String) throws
    func remountWhole(bsdName: String)               // devolve o cartão ao Finder quando a formatação desiste
    func suppressAutomount(bsdName: String)          // dissente montagens do disco durante o job
    func restoreAutomount()                          // idempotente
    func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice
    func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String   // ex.: "disk4s1"
    func unmount(bsdName: String) throws                                                   // fatia
    func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String)
    func mount(bsdName: String) throws
}
