import Foundation
import AppKit
import ServiceManagement
import CardFormatXPC

enum FormatPermission: Equatable { case notActivated, needsApproval, needsDiskAccess, ready, unavailable }

@MainActor protocol CardFormatting: AnyObject {
    var permission: FormatPermission { get }
    func refreshPermission()
    func activate()
    func openSystemSettings()
    func openDiskAccessSettings()
    func revealHelperInFinder()
    func format(_ request: FormatRequest, progress: @escaping @MainActor (FormatStep) -> Void) async -> FormatResponse
}

/// Permissão (SMAppService: aprovada uma vez nos Ajustes do Sistema e lembrada pelo macOS) + conexão XPC
/// com o ajudante que formata como administrador.
@MainActor @Observable
final class FormatController: CardFormatting {
    private(set) var permission: FormatPermission = .notActivated
    @ObservationIgnored private let service = SMAppService.daemon(plistName: CardFormatXPC.plistName)
    @ObservationIgnored private var repairTask: Task<Void, Never>?

    init() {
        let registered = UserDefaults.standard.string(forKey: Self.registeredBuildKey)
        if Self.shouldReRegister(isEnabled: service.status == .enabled, registeredBuild: registered,
                                 currentBuild: Self.currentBuild) {
            // Repara primeiro e só depois consulta XPC (evita corrida entre unregister e checkDiskAccess).
            Task { [weak self] in
                await self?.reRegister()
            }
        } else {
            refreshPermission()
        }
    }

    // MARK: Registro depois de atualizar

    static let registeredBuildKey = "formatHelper.registeredBuild"
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// Depois que o app é atualizado no disco (Sparkle, ou arrastando a versão nova), o macOS deixa o registro
    /// do ajudante emperrado ("needs LWCR update", saída 78) e não se recupera sozinho. Registrar de novo,
    /// uma vez por build, desemperra. Só pra quem já ativou: registrar sem pedido mostraria aviso do sistema.
    nonisolated static func shouldReRegister(isEnabled: Bool, registeredBuild: String?, currentBuild: String) -> Bool {
        isEnabled && registeredBuild != currentBuild
    }

    /// Serializa o reparo: chamadas simultâneas aguardam o mesmo Task em vez de desfazer o registro uma da outra.
    private func reRegister() async {
        if let existing = repairTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.service.unregister() } catch { NSLog("Cardflow: desfazer registro do ajudante: \(error)") }
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(1))
                self.register()
                if self.service.status == .enabled { break }
            }
            self.refreshPermission()
        }
        repairTask = task
        await task.value
        repairTask = nil
    }

    /// Registra (ou registra de novo) e anota o build quando ficou ativo.
    private func register() {
        do { try service.register() } catch { NSLog("Cardflow: registro do ajudante: \(error)") }
        if service.status == .enabled { UserDefaults.standard.set(Self.currentBuild, forKey: Self.registeredBuildKey) }
    }

    func refreshPermission() {
        switch service.status {
        case .enabled:
            // Aprovado; falta saber se o ajudante responde e tem Acesso Total ao Disco.
            checkDiskAccess()
        case .requiresApproval: permission = .needsApproval
        case .notRegistered: permission = .notActivated
        // Antes do primeiro register() o sistema costuma responder .notFound mesmo com tudo certo. Só é
        // "indisponível" de fato quando o plist do ajudante não está no bundle (ex.: rodando via swift run).
        case .notFound: permission = Self.helperIsBundled ? .notActivated : .unavailable
        @unknown default: permission = .unavailable
        }
    }

    static var helperIsBundled: Bool {
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(CardFormatXPC.plistName)")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    func activate() {
        if permission == .needsDiskAccess {   // já aprovado; o que falta é o Acesso Total ao Disco
            openDiskAccessSettings(); revealHelperInFinder(); return
        }
        register()
        refreshPermission()
        if permission == .needsApproval { openSystemSettings() }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    func openDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Mostra o binário do ajudante no Finder, pra arrastar pra lista do Acesso Total ao Disco.
    func revealHelperInFinder() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CardflowFormatHelper")
        NSWorkspace.shared.activateFileViewerSelecting([helper])
    }

    /// Pergunta ao ajudante (com timeout e limpeza de conexão) se ele tem Acesso Total ao Disco.
    private func checkDiskAccess() {
        let conn = NSXPCConnection(machServiceName: CardFormatXPC.machServiceName, options: .privileged)
        conn.remoteObjectInterface = CardFormatXPC.serviceInterface()
        conn.setCodeSigningRequirement(CardFormatXPC.helperRequirement)
        let once = OnceBox()
        let finish: (Bool?) -> Void = { [weak self] has in
            guard once.claim() else { return }
            conn.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.service.status == .enabled else { return }
                if let has {
                    self.permission = has ? .ready : .needsDiskAccess
                } else if self.permission == .notActivated || self.permission == .needsApproval {
                    // Ajudante habilitado mas não respondeu no prazo: mantém estado conhecido sem afirmar .ready à toa
                    self.permission = .needsDiskAccess
                }
            }
        }
        conn.interruptionHandler = { finish(nil) }
        conn.invalidationHandler = { finish(nil) }
        conn.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { finish(nil) }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? CardFormatServiceProtocol else {
            finish(nil); return
        }
        proxy.checkDiskAccess { has in finish(has) }
    }

    func format(_ request: FormatRequest, progress: @escaping @MainActor (FormatStep) -> Void) async -> FormatResponse {
        // Aguarda um eventual reparo já em andamento antes de testar o ajudante.
        if let pending = repairTask { await pending.value }
        if await !helperResponds() {
            NSLog("Cardflow: ajudante sem resposta; registrando de novo")
            await reRegister()
            if await !helperResponds(within: 20) {
                refreshPermission()
                return FormatResponse(failure: .helperUnavailable, detail: "o ajudante não respondeu", plan: nil)
            }
        }
        let resp = await sendFormat(request, progress: progress)
        if resp.failure == .diskAccessDenied {
            permission = .needsDiskAccess
        }
        return resp
    }

    /// O ajudante responde ao ping dentro do prazo?
    private func helperResponds(within seconds: Double = 6) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NSXPCConnection(machServiceName: CardFormatXPC.machServiceName, options: .privileged)
            conn.remoteObjectInterface = CardFormatXPC.serviceInterface()
            conn.setCodeSigningRequirement(CardFormatXPC.helperRequirement)
            let once = OnceBox()
            let finish: (Bool) -> Void = { ok in
                guard once.claim() else { return }
                conn.invalidate()
                cont.resume(returning: ok)
            }
            conn.interruptionHandler = { finish(false) }
            conn.invalidationHandler = { finish(false) }
            conn.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? CardFormatServiceProtocol
            else { finish(false); return }
            proxy.ping { _ in finish(true) }
        }
    }

    private func sendFormat(_ request: FormatRequest, progress: @escaping @MainActor (FormatStep) -> Void) async -> FormatResponse {
        await withCheckedContinuation { (cont: CheckedContinuation<FormatResponse, Never>) in
            let conn = NSXPCConnection(machServiceName: CardFormatXPC.machServiceName, options: .privileged)
            conn.remoteObjectInterface = CardFormatXPC.serviceInterface()
            conn.setCodeSigningRequirement(CardFormatXPC.helperRequirement)
            let once = OnceBox()
            let finish: (FormatResponse) -> Void = { r in
                guard once.claim() else { return }
                conn.invalidate()
                cont.resume(returning: r)
            }
            conn.interruptionHandler = { finish(FormatResponse(failure: .internalError, detail: "conexão interrompida", plan: nil)) }
            conn.invalidationHandler = { finish(FormatResponse(failure: .internalError, detail: "ajudante indisponível", plan: nil)) }
            conn.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                finish(FormatResponse(failure: .internalError, detail: "tempo esgotado aguardando o ajudante", plan: nil))
            }
            let relay = ProgressRelay { raw in
                guard !once.isClaimed, let s = FormatStep(rawValue: raw) else { return }
                Task { @MainActor in
                    guard !once.isClaimed else { return }
                    progress(s)
                }
            }
            let proxy = conn.remoteObjectProxyWithErrorHandler { err in
                finish(FormatResponse(failure: .internalError, detail: err.localizedDescription, plan: nil))
            } as? CardFormatServiceProtocol
            guard let proxy, let data = try? JSONEncoder().encode(request) else {
                finish(FormatResponse(failure: .internalError, detail: "sem conexão com o ajudante", plan: nil)); return
            }
            proxy.format(data, progress: relay) { reply in
                finish((try? JSONDecoder().decode(FormatResponse.self, from: reply))
                       ?? FormatResponse(failure: .internalError, detail: "resposta inválida", plan: nil))
            }
        }
    }
}

/// Recebe as etapas do ajudante (chega numa fila do XPC).
final class ProgressRelay: NSObject, CardFormatProgressProtocol {
    let onStep: (Int) -> Void
    init(_ onStep: @escaping (Int) -> Void) { self.onStep = onStep }
    func step(_ raw: Int) { onStep(raw) }
}

/// Garante que a continuação é retomada uma vez só (resposta, erro, interrupção e invalidação competem).
final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
