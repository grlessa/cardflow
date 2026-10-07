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

    init() {
        repairRegistrationAfterUpdate()
        refreshPermission()
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

    /// Só `register()` de novo não basta (o registro velho fica no launchd): desfaz e refaz.
    private func repairRegistrationAfterUpdate() {
        let registered = UserDefaults.standard.string(forKey: Self.registeredBuildKey)
        guard Self.shouldReRegister(isEnabled: service.status == .enabled, registeredBuild: registered,
                                    currentBuild: Self.currentBuild) else { return }
        Task { await reRegister() }
    }

    /// Registrar logo depois de desfazer não pega (o macOS ainda está limpando o registro velho): tenta de
    /// novo por alguns segundos. A aprovação dada antes continua valendo, sem pedir de novo.
    private func reRegister() async {
        do { try await service.unregister() } catch { NSLog("Cardflow: desfazer registro do ajudante: \(error)") }
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            register()
            if service.status == .enabled { break }
        }
        refreshPermission()
    }

    /// Registra (ou registra de novo) e anota o build quando ficou ativo.
    private func register() {
        do { try service.register() } catch { NSLog("Cardflow: registro do ajudante: \(error)") }
        if service.status == .enabled { UserDefaults.standard.set(Self.currentBuild, forKey: Self.registeredBuildKey) }
    }

    func refreshPermission() {
        switch service.status {
        case .enabled:
            // aprovado; falta saber se o ajudante tem Acesso Total ao Disco (sem ele, o leitor de SD
            // embutido recusa). Enquanto não responde, mantém o último estado conhecido.
            if permission != .needsDiskAccess { permission = .ready }
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
        // register() lança quando falta aprovação; o status (lido logo depois) diz o que aconteceu.
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

    /// Pergunta ao ajudante (que é quem precisa do acesso) se ele tem Acesso Total ao Disco.
    private func checkDiskAccess() {
        let conn = NSXPCConnection(machServiceName: CardFormatXPC.machServiceName, options: .privileged)
        conn.remoteObjectInterface = CardFormatXPC.serviceInterface()
        conn.setCodeSigningRequirement(CardFormatXPC.helperRequirement)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in conn.invalidate() } as? CardFormatServiceProtocol
        proxy?.checkDiskAccess { has in
            conn.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.service.status == .enabled else { return }
                self.permission = has ? .ready : .needsDiskAccess
            }
        }
    }

    func format(_ request: FormatRequest, progress: @escaping @MainActor (FormatStep) -> Void) async -> FormatResponse {
        // Sem ajudante de pé, a conexão XPC espera para sempre. Confere antes; se não responde, registra de
        // novo (o launchd tenta subir a cada ~10 s) e, como último recurso, desfaz e refaz o registro.
        if await !helperResponds() {
            NSLog("Cardflow: ajudante sem resposta; registrando de novo")
            await reRegister()
            if await !helperResponds(within: 25) {
                await reRegister()
                if await !helperResponds(within: 25) {
                    refreshPermission()
                    return FormatResponse(failure: .helperUnavailable, detail: "o ajudante não respondeu", plan: nil)
                }
            }
        }
        return await sendFormat(request, progress: progress)
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
            let relay = ProgressRelay { raw in
                if let s = FormatStep(rawValue: raw) { Task { @MainActor in progress(s) } }
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
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
