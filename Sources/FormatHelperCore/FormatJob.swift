import Foundation
import os
import CardFormatKit
import CardFormatXPC

/// Sequência da formatação. Antes de escrever: valida e desmonta (qualquer falha = nada escrito).
/// Depois de escrever: confere sempre; falha na conferência é reportada como falha, nunca como sucesso.
public struct FormatJob {
    /// Registro de cada etapa e de cada falha (Console.app → processo CardflowFormatHelper). Público de
    /// propósito: é a única forma de diagnosticar um cartão real sem reproduzir no Mac de quem testou.
    static let log = Logger(subsystem: "com.cardflow.app.formathelper", category: "format")
    let system: DiskSystem
    let mbrSignature: () -> UInt32
    let volumeSerial: () -> UInt32

    public init(system: DiskSystem, mbrSignature: @escaping () -> UInt32 = MBR.randomSignature,
                volumeSerial: @escaping () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }) {
        self.system = system; self.mbrSignature = mbrSignature; self.volumeSerial = volumeSerial
    }

    public func run(_ request: FormatRequest, progress onStep: (FormatStep) -> Void) -> FormatResponse {
        func progress(_ step: FormatStep) {
            Self.log.info("etapa \(String(describing: step), privacy: .public) em \(request.bsdName, privacy: .public)")
            onStep(step)
        }
        progress(.validating)
        let plan: FormatPlan
        do {
            let d = try system.describe(bsdName: request.bsdName)
            switch DeviceGuard.validate(d, request: request) {
            case .success(let p): plan = p
            case .failure(.cardChanged): return fail(.cardChanged, "volume diferente do conferido")
            case .failure(.sizeMismatch): return fail(.cardChanged, "tamanho diferente do conferido")
            case .failure(.plan(let e)): return fail(.planRejected, "\(e)")
            case .failure(let e): return fail(.deviceRejected, "\(e)")
            }
        } catch { return fail(.internalError, "descrever disco: \(error)") }

        system.suppressAutomount(bsdName: request.bsdName)
        defer { system.restoreAutomount() }

        progress(.unmounting)
        do { try system.unmountWhole(bsdName: request.bsdName) }
        catch { return fail(.unmountFailed, "\(error)", plan) }

        progress(.partitioning)
        let slice: String
        let dev: BlockDevice
        do { dev = try system.openRaw(bsdName: request.bsdName, sectorCount: plan.totalSectors) }
        catch {
            // nada foi escrito: o cartão está intacto, então volta pro Finder (antes ficava desmontado)
            system.restoreAutomount()
            system.remountWhole(bsdName: request.bsdName)
            if let e = error as? BlockDeviceError, e.errno == EPERM {
                return fail(.diskAccessDenied, "abrir o disco: errno 1 (o macOS negou; falta Acesso Total ao Disco)", plan)
            }
            return fail(.writeFailed, "abrir o disco: \(error)", plan)
        }
        do {
            switch plan.fileSystem {
            case .exfat:
                progress(.writingFileSystem)
                try ExFATVolumeWriter(plan: plan, label: request.label, volumeSerial: volumeSerial())
                    .write(to: dev, mbrSignature: mbrSignature())
                (dev as? FileBlockDevice)?.close()
                slice = try system.waitForSlice(bsdName: request.bsdName, slice: 1, timeout: 15)
            case .fat32:
                try FAT32Format.writePartitionTable(plan: plan, to: dev, mbrSignature: mbrSignature())
                (dev as? FileBlockDevice)?.close()
                slice = try system.waitForSlice(bsdName: request.bsdName, slice: 1, timeout: 15)
                progress(.writingFileSystem)
                let r = try system.run(FAT32Format.newfsPath,
                                       FAT32Format.newfsArguments(plan: plan, label: request.label, partitionRawDevice: "/dev/r\(slice)"))
                guard r.status == 0 else { return fail(.writeFailed, "newfs_msdos \(r.status): \(r.output)", plan) }
            }
        } catch { return fail(.writeFailed, "\(error)", plan) }

        progress(.verifying)
        do {
            try? system.unmount(bsdName: slice)   // se o sistema montou sozinho, solta pra conferir
            let dev = try system.openRaw(bsdName: request.bsdName, sectorCount: plan.totalSectors)
            let issues = PostFormatVerifier.issues(device: dev, plan: plan)
            (dev as? FileBlockDevice)?.close()
            guard issues.isEmpty else { return fail(.verifyFailed, issues.joined(separator: "; "), plan) }
            let fsck = plan.fileSystem == .exfat ? "/sbin/fsck_exfat" : "/sbin/fsck_msdos"
            let r = try system.run(fsck, ["-n", "/dev/r\(slice)"])
            guard r.status == 0 else { return fail(.fsckFailed, r.output, plan) }
        } catch { return fail(.verifyFailed, "\(error)", plan) }

        progress(.remounting)
        system.restoreAutomount()
        try? system.mount(bsdName: slice)        // não remontar não é falha: o app ejeta em seguida
        return FormatResponse(failure: nil, detail: nil, plan: plan)
    }

    private func fail(_ f: FormatFailure, _ detail: String, _ plan: FormatPlan? = nil) -> FormatResponse {
        Self.log.error("falha \(f.rawValue, privacy: .public): \(detail, privacy: .public)")
        return FormatResponse(failure: f, detail: detail, plan: plan)
    }
}
