import Foundation

/// Fila serial de cópias: um cartão por vez, na ordem em que foram pedidos. Dois cartões copiando ao
/// mesmo tempo pro mesmo disco brigariam pelo disco e ficariam mais lentos que um depois do outro.
/// A falha de um não trava os outros: quem roda (`run`) trata o próprio erro.
@MainActor @Observable
final class CopyQueue {
    private(set) var order: [String] = []    // esperando a vez (sem o que está rodando)
    private(set) var running: String?
    @ObservationIgnored private let run: @MainActor (String) async -> Void

    init(run: @escaping @MainActor (String) async -> Void) { self.run = run }

    var isIdle: Bool { running == nil && order.isEmpty }

    func enqueue(_ id: String) {
        guard running != id, !order.contains(id) else { return }
        order.append(id)
        pump()
    }

    /// Tira da espera (o que já está rodando só para pelo botão Parar).
    func remove(_ id: String) { order.removeAll { $0 == id } }

    /// Posição na espera, a partir de 1.
    func position(of id: String) -> Int? { order.firstIndex(of: id).map { $0 + 1 } }

    private func pump() {
        guard running == nil, !order.isEmpty else { return }
        let next = order.removeFirst()
        running = next
        Task { @MainActor in
            await run(next)
            running = nil
            pump()
        }
    }
}
