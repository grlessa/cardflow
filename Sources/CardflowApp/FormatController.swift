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

    init() { refreshPermission() }

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
        do { try service.register() } catch { NSLog("Cardflow: registro do ajudante: \(error)") }
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
