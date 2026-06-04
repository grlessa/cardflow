import Testing
import Foundation
@testable import OffloadKit

private struct StubSpace: FreeSpaceProviding {
    let map: [String: Int64]
    func availableBytes(at url: URL) throws -> Int64 { map[url.path] ?? 0 }
}

@Suite struct SpaceCheckerTests {
    @Test func noShortfallWhenEverythingFits() throws {
        let a = URL(fileURLWithPath: "/Volumes/SSD")
        let b = URL(fileURLWithPath: "/Volumes/HD")
        let checker = SpaceChecker(provider: StubSpace(map: ["/Volumes/SSD": 200, "/Volumes/HD": 200]))
        let shortfalls = try checker.check(requiredBytesPerDestination: 80, destinations: [a, b], marginBytes: 10)
        #expect(shortfalls.isEmpty)
    }

    @Test func reportsOnlyTheShortDestination() throws {
        let a = URL(fileURLWithPath: "/Volumes/SSD") // 50 livre, precisa 80+10 → falta
        let b = URL(fileURLWithPath: "/Volumes/HD")  // 999 livre → ok
        let checker = SpaceChecker(provider: StubSpace(map: ["/Volumes/SSD": 50, "/Volumes/HD": 999]))
        let shortfalls = try checker.check(requiredBytesPerDestination: 80, destinations: [a, b], marginBytes: 10)
        #expect(shortfalls.count == 1)
        #expect(shortfalls.first?.destination == a)
        #expect(shortfalls.first?.required == 90)
        #expect(shortfalls.first?.available == 50)
    }
}
