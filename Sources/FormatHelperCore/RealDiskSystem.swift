import Foundation
import os
import DiskArbitration
import CardFormatKit

/// Operações reais (root). DiskArbitration roda numa fila própria; as chamadas assíncronas viram síncronas.
public final class RealDiskSystem: DiskSystem {
    static let log = Logger(subsystem: "com.cardflow.app.formathelper", category: "disk")
    private let session: DASession
    private let queue = DispatchQueue(label: "com.cardflow.app.formathelper.da")
    private let lock = NSLock()
    private var approvalTarget: String?
    private var approvalRegistered = false

    public init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, queue)
    }

    private func disk(_ bsd: String) throws -> DADisk {
        guard let d = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            throw NSError(domain: "RealDiskSystem", code: 1, userInfo: [NSLocalizedDescriptionKey: "disco \(bsd) não existe"])
        }
        return d
    }

    public func describe(bsdName: String) throws -> DiskDescription {
        let d = try disk(bsdName)
        guard let desc = DADiskCopyDescription(d) as? [CFString: Any] else {
            throw NSError(domain: "RealDiskSystem", code: 2, userInfo: [NSLocalizedDescriptionKey: "sem descrição de \(bsdName)"])
        }
        let bootBSD: String? = {
            guard let root = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: "/") as CFURL),
                  let whole = DADiskCopyWholeDisk(root), let b = DADiskGetBSDName(whole) else { return nil }
            return String(cString: b)
        }()
        var kinds: [String] = [], uuids: [String] = []
        for i in 1...16 {
            let sliceName = "\(bsdName)s\(i)"
            guard FileManager.default.fileExists(atPath: "/dev/\(sliceName)"),
                  let s = DADiskCreateFromBSDName(kCFAllocatorDefault, session, sliceName),
                  let sd = DADiskCopyDescription(s) as? [CFString: Any] else { continue }
            if let k = sd[kDADiskDescriptionVolumeKindKey] as? String { kinds.append(k) }
            if let u = sd[kDADiskDescriptionVolumeUUIDKey], CFGetTypeID(u as CFTypeRef) == CFUUIDGetTypeID() {
                uuids.append(CFUUIDCreateString(nil, (u as! CFUUID)) as String)
            }
            if let content = sd[kDADiskDescriptionMediaContentKey] as? String,
               content.contains("Apple_APFS") || content.contains("Apple_HFS") { kinds.append("apfs") }
        }
        return DiskDescription(
            bsdName: bsdName,
            isWhole: (desc[kDADiskDescriptionMediaWholeKey] as? Bool) ?? false,
            isRemovable: (desc[kDADiskDescriptionMediaRemovableKey] as? Bool) ?? false,
            isEjectable: (desc[kDADiskDescriptionMediaEjectableKey] as? Bool) ?? false,
            isInternal: (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? true,
            isWritable: (desc[kDADiskDescriptionMediaWritableKey] as? Bool) ?? false,
            totalBytes: (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0,
            blockSize: (desc[kDADiskDescriptionMediaBlockSizeKey] as? NSNumber)?.intValue ?? 0,
            containsBootVolume: bootBSD == bsdName,
            partitionFileSystems: kinds, volumeUUIDs: uuids)
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

    /// Enquanto formata, recusa montagens das fatias do disco-alvo (evita o alerta de "disco ilegível" e o
    /// sistema montando no meio do caminho). `restoreAutomount` desliga.
    public func suppressAutomount(bsdName: String) {
        lock.lock(); approvalTarget = bsdName; let registered = approvalRegistered; approvalRegistered = true; lock.unlock()
        guard !registered else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskMountApprovalCallback(session, nil, { disk, ctx in
            let me = Unmanaged<RealDiskSystem>.fromOpaque(ctx!).takeUnretainedValue()
            guard let target = me.currentTarget(), let b = DADiskGetBSDName(disk),
                  String(cString: b).hasPrefix(target + "s") else { return nil }
            return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy),
                                                            "Cardflow formatando" as CFString))
        }, ctx)
    }

    private func currentTarget() -> String? { lock.lock(); defer { lock.unlock() }; return approvalTarget }

    public func restoreAutomount() { lock.lock(); approvalTarget = nil; lock.unlock() }

    /// Abre o disco cru pra escrita. No leitor de SD EMBUTIDO do Mac, o macOS nega (EPERM) mesmo pra root
    /// enquanto o ajudante não tiver Acesso Total ao Disco; USB e imagens abrem direto. O EPERM sobe como
    /// BlockDeviceError e vira `.diskAccessDenied` no FormatJob.
    public func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice {
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
        let name = "\(bsdName)s\(slice)"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "/dev/\(name)") { return name }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NSError(domain: "RealDiskSystem", code: 4, userInfo: [NSLocalizedDescriptionKey: "partição \(name) não apareceu"])
    }

    public func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()   // lê antes do wait: saída grande não trava
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}

private final class DABox {
    let sem = DispatchSemaphore(value: 0)
    var status: DAReturn = DAReturn(kDAReturnSuccess)
}
