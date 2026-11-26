import Testing
import Foundation
@testable import FormatHelperCore
import CardFormatKit
import CardFormatXPC

private final class DummyProgress: NSObject, CardFormatProgressProtocol {
    var steps: [Int] = []
    func step(_ raw: Int) { steps.append(raw) }
}

@Suite struct HelperServiceTests {
    @Test func pingRespondeOk() async {
        let service = HelperService()
        let reply = await withCheckedContinuation { cont in
            service.ping { cont.resume(returning: $0) }
        }
        #expect(reply == "ok")
        #expect(!service.isBusy)
    }

    @Test func pedidoInvalidoRetornaInternalError() async throws {
        let service = HelperService()
        let data = await withCheckedContinuation { cont in
            service.format(Data("lixo".utf8), progress: DummyProgress()) { cont.resume(returning: $0) }
        }
        let resp = try JSONDecoder().decode(FormatResponse.self, from: data)
        #expect(resp.failure == .internalError)
        #expect(!service.isBusy)
    }

    @Test func segundoPedidoSimultaneoRecebeBusy() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        final class BlockingSystem: DiskSystem {
            let entered: DispatchSemaphore; let release: DispatchSemaphore
            init(entered: DispatchSemaphore, release: DispatchSemaphore) { self.entered = entered; self.release = release }
            func describe(bsdName: String) throws -> DiskDescription {
                entered.signal(); release.wait()
                throw NSError(domain: "test", code: 1)
            }
            func unmountWhole(bsdName: String) throws {}
            func remountWhole(bsdName: String) {}
            func suppressAutomount(bsdName: String) {}
            func restoreAutomount() {}
            func openRaw(bsdName: String, sectorCount: UInt64) throws -> BlockDevice { fatalError() }
            func waitForSlice(bsdName: String, slice: Int, timeout: TimeInterval) throws -> String { "" }
            func unmount(bsdName: String) throws {}
            func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) { (0, "") }
            func mount(bsdName: String) throws {}
        }

        let service = HelperService { FormatJob(system: BlockingSystem(entered: entered, release: release)) }
        let reqData = try JSONEncoder().encode(FormatRequest(bsdName: "disk4", expectedTotalBytes: 64_000_000_000, expectedVolumeUUID: nil, label: "X"))

        let firstDone = DispatchSemaphore(value: 0)
        let box = Unmanaged.passRetained(service)
        DispatchQueue.global().async {
            let s = box.takeRetainedValue()
            s.format(reqData, progress: DummyProgress()) { _ in firstDone.signal() }
        }
        entered.wait()
        #expect(service.isBusy)

        var secondData = Data()
        let secondDone = DispatchSemaphore(value: 0)
        service.format(reqData, progress: DummyProgress()) { d in
            secondData = d
            secondDone.signal()
        }
        secondDone.wait()
        let secondResp = try JSONDecoder().decode(FormatResponse.self, from: secondData)
        #expect(secondResp.failure == .busy)

        release.signal()
        firstDone.wait()
        #expect(!service.isBusy)
    }
}
