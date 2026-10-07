import Foundation
import CardFormatXPC

/// Objeto exportado no XPC. Uma formatação por vez; pedidos concorrentes recebem `.busy`.
public final class HelperService: NSObject, CardFormatServiceProtocol {
    private let makeJob: () -> FormatJob
    private let lock = NSLock()
    private var running = false

    public init(makeJob: @escaping () -> FormatJob = { FormatJob(system: RealDiskSystem()) }) { self.makeJob = makeJob }

    /// Formatando agora? (o daemon não encerra por ociosidade no meio de um trabalho)
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return running }

    public func ping(reply: @escaping (String) -> Void) { reply("ok") }

    public func checkDiskAccess(reply: @escaping (Bool) -> Void) { reply(RealDiskSystem.hasFullDiskAccess()) }

    public func format(_ request: Data, progress: CardFormatProgressProtocol, reply: @escaping (Data) -> Void) {
        let enc = JSONEncoder()
        lock.lock()
        if running {
            lock.unlock()
            reply((try? enc.encode(FormatResponse(failure: .busy, detail: nil, plan: nil))) ?? Data()); return
        }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        guard let req = try? JSONDecoder().decode(FormatRequest.self, from: request) else {
            reply((try? enc.encode(FormatResponse(failure: .internalError, detail: "pedido inválido", plan: nil))) ?? Data()); return
        }
        let resp = makeJob().run(req) { progress.step($0.rawValue) }
        reply((try? enc.encode(resp)) ?? Data())
    }
}
