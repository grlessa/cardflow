import Testing
import Foundation
@testable import CardflowApp

@MainActor @Suite struct CopyQueueTests {
    func waitIdle(_ q: CopyQueue) async {
        for _ in 0..<500 where !q.isIdle { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test func rodaUmDeCadaVezNaOrdem() async {
        var log: [String] = []
        let q = CopyQueue { id in log.append("start \(id)"); try? await Task.sleep(nanoseconds: 5_000_000); log.append("end \(id)") }
        q.enqueue("A"); q.enqueue("B"); q.enqueue("A")
        #expect(q.running == "A" && q.position(of: "B") == 1)
        await waitIdle(q)
        #expect(log == ["start A", "end A", "start B", "end B"])
    }
    @Test func removerAntesDeComecar() async {
        var ran: [String] = []
        let q = CopyQueue { id in ran.append(id); try? await Task.sleep(nanoseconds: 5_000_000) }
        q.enqueue("A"); q.enqueue("B"); q.remove("B")
        await waitIdle(q)
        #expect(ran == ["A"])
    }
    @Test func falhaDeUmNaoTravaOsOutros() async {
        var ran: [String] = []
        let q = CopyQueue { id in ran.append(id); if id == "A" { return } }   // "falha" = retorna cedo
        q.enqueue("A"); q.enqueue("B"); q.enqueue("C")
        await waitIdle(q)
        #expect(ran == ["A", "B", "C"])
    }
}
