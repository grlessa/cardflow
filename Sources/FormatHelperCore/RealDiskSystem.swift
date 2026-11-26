import Foundation
import os
import DiskArbitration
import IOKit
import CardFormatKit

/// Operações reais (root). DiskArbitration roda numa fila própria; as chamadas assíncronas viram síncronas.
public final class RealDiskSystem: DiskSystem {
    static let log = Logger(subsystem: "com.cardflow.app.formathelper", category: "disk")
    private static let apfsContainerSchemeGUID = "EF57347C-0000-11AA-AA11-00306543ECAC"
    private static let apfsPartitionGUID = "7C3457EF-0000-11AA-AA11-00306543ECAC"
    private static let hfsPartitionGUID = "48465300-0000-11AA-AA11-00306543ECAC"
    private static let efiPartitionGUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    private static let processTimeout: TimeInterval = 120

    private let session: DASession
    private let queue = DispatchQueue(label: "com.cardflow.app.formathelper.da")
    private let lock = NSLock()
    private var approvalTarget: String?
    private var approvalRegistered = false
    private var invalidated = false
    private var claimedDisk: DADisk?
    private var expectedRegistryIDs: [String: UInt64] = [:]

    public init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, queue)
    }

    deinit { invalidate() }

    /// Desregistra callbacks e desacopla a DASession antes de liberar a instância (evita use-after-free
    /// no daemon root quando outro disco monta durante a janela de ociosidade).
    public func invalidate() {
        lock.lock()
        if invalidated { lock.unlock(); return }
        invalidated = true
        approvalTarget = nil
        let hadApproval = approvalRegistered
        approvalRegistered = false
        let claimed = claimedDisk
        claimedDisk = nil
        lock.unlock()

        if let claimed { DADiskUnclaim(claimed) }
        if hadApproval {
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            let cb = unsafeBitCast(Self.mountApprovalCallback, to: UnsafeMutableRawPointer.self)
            DAUnregisterCallback(session, cb, ctx)
        }
        DASessionSetDispatchQueue(session, nil)
        // Drena qualquer callback que já estava em trânsito na fila antes de liberar `self`.
        queue.sync {}
    }

    private func disk(_ bsd: String) throws -> DADisk {
        guard let d = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            throw NSError(domain: "RealDiskSystem", code: 1, userInfo: [NSLocalizedDescriptionKey: "disco \(bsd) não existe"])
        }
        return d
    }

    /// Coleta todos os discos inteiros (sintetizados e físicos subjacentes) que sustentam o volume de boot.
    private func bootDiskBSDNames() -> Set<String> {
        var names: Set<String> = []
        for path in ["/", "/System/Volumes/Data"] {
            guard let vol = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL) else { continue }
            if let whole = DADiskCopyWholeDisk(vol), let b = DADiskGetBSDName(whole) {
                names.insert(String(cString: b))
            }
            let media = DADiskCopyIOMedia(vol)
            if media != 0 {
                defer { IOObjectRelease(media) }
                names.formUnion(Self.backingWholeDiskBSDNames(of: media))
            }
        }
        return names
    }

    private static func backingWholeDiskBSDNames(of media: io_service_t) -> Set<String> {
        var result: Set<String> = []
        var visited: Set<UInt64> = []
        var stack: [io_registry_entry_t] = []
        IOObjectRetain(media)
        stack.append(media)
        while let entry = stack.popLast() {
            defer { IOObjectRelease(entry) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS {
                if !visited.insert(entryID).inserted { continue }
            }
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
               whole,
               let bsd = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                result.insert(bsd)
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
        return result
    }

    private static func registryEntryID(of disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    private static func sliceGeometry(of disk: DADisk) -> (base: UInt64, size: UInt64)? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        guard let base = IORegistryEntryCreateCFProperty(media, "Base" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              let size = IORegistryEntryCreateCFProperty(media, "Size" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return (base.uint64Value, size.uint64Value)
    }

    private static func isSynthesizedAPFS(disk: DADisk, desc: [CFString: Any]) -> Bool {
        if let content = desc[kDADiskDescriptionMediaContentKey] as? String,
           content.caseInsensitiveCompare(apfsContainerSchemeGUID) == .orderedSame {
            return true
        }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        return IOObjectConformsTo(media, "AppleAPFSContainerScheme") != 0
    }

    public func describe(bsdName: String) throws -> DiskDescription {
        guard DeviceGuard.isValidWholeDiskBSD(bsdName) else {
            throw NSError(domain: "RealDiskSystem", code: 5, userInfo: [NSLocalizedDescriptionKey: "nome de disco inválido: \(bsdName)"])
        }
        let d = try disk(bsdName)
        guard let desc = DADiskCopyDescription(d) as? [CFString: Any],
              let rawBSD = DADiskGetBSDName(d) else {
            throw NSError(domain: "RealDiskSystem", code: 2, userInfo: [NSLocalizedDescriptionKey: "sem descrição de \(bsdName)"])
        }
        let actualBSD = String(cString: rawBSD)
        if let entryID = Self.registryEntryID(of: d) {
            lock.lock(); expectedRegistryIDs[actualBSD] = entryID; lock.unlock()
        }
        let bootBSDs = bootDiskBSDNames()
        let synthesizedAPFS = Self.isSynthesizedAPFS(disk: d, desc: desc)

        var kinds: [String] = [], uuids: [String] = []
        var sliceCount = 0
        for i in 1...16 {
            let sliceName = "\(actualBSD)s\(i)"
            guard FileManager.default.fileExists(atPath: "/dev/\(sliceName)"),
                  let s = DADiskCreateFromBSDName(kCFAllocatorDefault, session, sliceName),
                  let sd = DADiskCopyDescription(s) as? [CFString: Any] else { continue }
            sliceCount += 1
            if let u = sd[kDADiskDescriptionVolumeUUIDKey], CFGetTypeID(u as CFTypeRef) == CFUUIDGetTypeID() {
                uuids.append(CFUUIDCreateString(nil, (u as! CFUUID)) as String)
            }
            let content = (sd[kDADiskDescriptionMediaContentKey] as? String) ?? ""
            let upper = content.uppercased()
            if upper == Self.apfsPartitionGUID || content.contains("Apple_APFS") {
                kinds.append("apfs")
            } else if upper == Self.hfsPartitionGUID || content.contains("Apple_HFS") {
                kinds.append("hfs")
            } else if upper == Self.efiPartitionGUID || content == "EFI" {
                kinds.append("efi")
            } else if let k = sd[kDADiskDescriptionVolumeKindKey] as? String, !k.isEmpty {
                kinds.append(k)
            } else {
                // Qualquer fatia sem VolumeKind conhecido (partição desmontada, Linux, NTFS, BitLocker...)
                // precisa aparecer para o DeviceGuard barrar via allowlist.
                kinds.append(content.isEmpty ? "unknown" : content)
            }
        }
        return DiskDescription(
            bsdName: actualBSD,
            isWhole: (desc[kDADiskDescriptionMediaWholeKey] as? Bool) ?? false,
            isRemovable: (desc[kDADiskDescriptionMediaRemovableKey] as? Bool) ?? false,
            isEjectable: (desc[kDADiskDescriptionMediaEjectableKey] as? Bool) ?? false,
            isInternal: (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? true,
            isWritable: (desc[kDADiskDescriptionMediaWritableKey] as? Bool) ?? false,
            totalBytes: (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0,
            blockSize: (desc[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber)?.intValue ?? 0,
            containsBootVolume: bootBSDs.contains(actualBSD),
            partitionFileSystems: kinds, volumeUUIDs: uuids,
            sliceCount: sliceCount, isSynthesizedAPFS: synthesizedAPFS)
    }

    /// Espera o callback do DiskArbitration (até 30 s); dissenter = falha com o status dele.
    private func waitDA(_ start: (UnsafeMutableRawPointer) -> Void) throws {
        let box = DABox()
        start(Unmanaged.passRetained(box).toOpaque())
        guard box.sem.wait(timeout: .now() + 30) == .success else {
            throw NSError(domain: "RealDiskSystem", code: 3, userInfo: [NSLocalizedDescriptionKey: "tempo esgotado"])
        }
        guard box.status == DAReturn(kDAReturnSuccess) else {
            throw NSError(domain: "RealDiskSystem", code: Int(box.status), userInfo: [NSLocalizedDescriptionKey: "DiskArbitration \(box.status)"])
        }
    }

    private static let daCallback: DADiskUnmountCallback = { _, dissenter, ctx in
        let box = Unmanaged<DABox>.fromOpaque(ctx!).takeRetainedValue()
        if let dissenter { box.status = DADissenterGetStatus(dissenter) }
        box.sem.signal()
    }

    public func claim(bsdName: String) throws {
        let d = try disk(bsdName)
        try waitDA { DADiskClaim(d, DADiskClaimOptions(kDADiskClaimOptionDefault), nil, nil, Self.daCallback, $0) }
        lock.lock(); claimedDisk = d; lock.unlock()
    }

    public func unclaim(bsdName: String) {
        lock.lock(); let d = claimedDisk; claimedDisk = nil; lock.unlock()
        if let d { DADiskUnclaim(d) }
    }

    public func unmountWhole(bsdName: String) throws {
        let d = try disk(bsdName)
        try waitDA { DADiskUnmount(d, DADiskUnmountOptions(kDADiskUnmountOptionWhole), Self.daCallback, $0) }
    }

    /// Monta de novo todos os volumes do disco (o cartão volta pro Finder). Melhor esforço: sem erro.
    public func remountWhole(bsdName: String) {
        guard let d = try? disk(bsdName) else { return }
        try? waitDA { DADiskMount(d, nil, DADiskMountOptions(kDADiskMountOptionWhole), Self.daCallback, $0) }
    }

    public func unmount(bsdName: String) throws {
        let d = try disk(bsdName)
        try waitDA { DADiskUnmount(d, DADiskUnmountOptions(kDADiskUnmountOptionDefault), Self.daCallback, $0) }
    }

    public func mount(bsdName: String) throws {
        let d = try disk(bsdName)
        try waitDA { DADiskMount(d, nil, DADiskMountOptions(kDADiskMountOptionDefault), Self.daCallback, $0) }
    }

    private static let mountApprovalCallback: DADiskMountApprovalCallback = { disk, ctx in
        let me = Unmanaged<RealDiskSystem>.fromOpaque(ctx!).takeUnretainedValue()
        guard let target = me.currentTarget(), let b = DADiskGetBSDName(disk),
              String(cString: b).hasPrefix(target + "s") else { return nil }
        return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy),
                                                        "Cardflow formatando" as CFString))
    }

    /// Enquanto formata, recusa montagens das fatias do disco-alvo (evita o alerta de "disco ilegível" e o
    /// sistema montando no meio do caminho). `restoreAutomount` desliga.
    public func suppressAutomount(bsdName: String) {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        approvalTarget = bsdName
        let registered = approvalRegistered
        approvalRegistered = true
        lock.unlock()
        guard !registered else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, Self.mountApprovalCallback, ctx)
    }

    private func currentTarget() -> String? { lock.lock(); defer { lock.unlock() }; return approvalTarget }

    public func restoreAutomount() { lock.lock(); approvalTarget = nil; lock.unlock() }

    /// Abre o disco cru pra escrita. Reconfirma a identidade IOKit do disco antes de escrever (fecha TOCTOU
    /// entre `describe` e `openRaw`). No leitor de SD EMBUTIDO do Mac, o macOS nega (EPERM) mesmo pra root
    /// enquanto o ajudante não tiver Acesso Total ao Disco; USB e imagens abrem direto.
    public func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice {
        guard DeviceGuard.isValidWholeDiskBSD(bsdName) else {
            throw BlockDeviceError(operation: "open (nome inválido)", errno: EINVAL)
        }
        lock.lock(); let expectedID = expectedRegistryIDs[bsdName]; lock.unlock()
        if let expectedID {
            let d = try disk(bsdName)
            guard Self.registryEntryID(of: d) == expectedID else {
                throw BlockDeviceError(operation: "open (disco trocado)", errno: ENODEV)
            }
        }
        let path = "/dev/r\(bsdName)"
        do { return try FileBlockDevice(path: path, sectorCount: sectorCount, exclusive: true) }
        catch let e as BlockDeviceError {
            Self.log.error("open \(path, privacy: .public) errno \(e.errno, privacy: .public)")
            throw e
        }
    }

    /// O ajudante tem Acesso Total ao Disco? Teste clássico: abrir o banco do TCC do sistema, que só abre
    /// com esse acesso (mesmo pra root).
    public static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    public func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String {
        try waitForSlice(bsdName: bsdName, slice: slice, expectedStartSector: nil, expectedSectorCount: nil, timeout: timeout)
    }

    /// Espera a fatia `diskNs1` existir E, quando a geometria esperada for informada, corresponder ao
    /// início e tamanho do plano recém-gravado (evita rodar `newfs_msdos`/`fsck` sobre uma fatia antiga).
    public func waitForSlice(bsdName: String, slice: Int, expectedStartSector: UInt64?, expectedSectorCount: UInt64?, timeout: TimeInterval) throws -> String {
        let name = "\(bsdName)s\(slice)"
        let expectedBase = expectedStartSector.map { $0 * 512 }
        let expectedSize = expectedSectorCount.map { $0 * 512 }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "/dev/\(name)") {
                if expectedBase == nil && expectedSize == nil { return name }
                if let s = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
                   let geo = Self.sliceGeometry(of: s),
                   (expectedBase == nil || geo.base == expectedBase),
                   (expectedSize == nil || geo.size == expectedSize) {
                    return name
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw NSError(domain: "RealDiskSystem", code: 4, userInfo: [NSLocalizedDescriptionKey: "partição \(name) não apareceu com o layout esperado"])
    }

    public func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        try p.run()
        DispatchQueue.global(qos: .userInitiated).async {
            data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            readDone.signal()
        }
        if done.wait(timeout: .now() + Self.processTimeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 5)
            throw NSError(domain: "RealDiskSystem", code: 6, userInfo: [NSLocalizedDescriptionKey: "tempo esgotado executando \(tool)"])
        }
        _ = readDone.wait(timeout: .now() + 5)
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private final class DABox {
    let sem = DispatchSemaphore(value: 0)
    var status: DAReturn = DAReturn(kDAReturnSuccess)
}
