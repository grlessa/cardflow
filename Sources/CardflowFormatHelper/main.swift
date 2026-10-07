import Foundation
import CardFormatXPC
import FormatHelperCore

/// Daemon do launchd (registrado pelo app via SMAppService). Só aceita conexões do Cardflow assinado
/// pelo mesmo time; só expõe a operação de formatar. Sobe sob demanda e encerra quando fica ocioso, pra
/// que uma versão nova do app (binário novo do ajudante) entre em uso sem reiniciar o Mac.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()
    private let lock = NSLock()
    private var openConnections = 0
    private var idleTimer: DispatchSourceTimer?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = CardFormatXPC.serviceInterface()
        c.exportedObject = service
        c.invalidationHandler = { [weak self] in self?.connectionEnded() }
        lock.lock(); openConnections += 1; idleTimer?.cancel(); idleTimer = nil; lock.unlock()
        c.resume()
        return true
    }

    private func connectionEnded() {
        lock.lock(); openConnections -= 1; let idle = openConnections <= 0; lock.unlock()
        if idle { scheduleIdleExit() }
    }

    /// Sem conexão aberta por 60 s → sai. O launchd sobe de novo no próximo pedido do app.
    func scheduleIdleExit() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = self.openConnections <= 0; self.lock.unlock()
            if idle && !self.service.isBusy { exit(0) }
        }
        lock.lock(); idleTimer?.cancel(); idleTimer = t; lock.unlock()
        t.resume()
    }
}

let listener = NSXPCListener(machServiceName: CardFormatXPC.machServiceName)
listener.setConnectionCodeSigningRequirement(CardFormatXPC.clientRequirement)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
delegate.scheduleIdleExit()   // subiu sem ninguém conectar (ex.: launchd no boot) → não fica pendurado
RunLoop.main.run()
