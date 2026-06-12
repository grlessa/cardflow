import Testing
@testable import CardflowApp

@MainActor
@Suite struct VolumeWatcherTests {
    @Test func startIsIdempotent() {
        let watcher = VolumeWatcher()
        watcher.start()
        let first = watcher.observerCount
        watcher.start()
        #expect(watcher.observerCount == first)
    }
}
