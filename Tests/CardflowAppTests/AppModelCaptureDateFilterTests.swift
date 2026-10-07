import Foundation
import Testing
@testable import OffloadKit
@testable import CardflowApp

@MainActor
@Suite struct AppModelCaptureDateFilterTests {
    @Test func defaultFilterCopiesAllFiles() {
        let model = AppModel.withTestCard()
        #expect(model.cards[0].captureDateFilter == .all)
        #expect(model.cards[0].capturedIn == nil)
    }

    @Test func todayUsesAnchorDay() throws {
        let model = AppModel.withTestCard()
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        model.setCaptureDateFilter(.today(anchor: anchor), for: model.cards[0])

        let interval = try #require(model.cards[0].capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: anchor)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    @Test func todayAnchorDoesNotMoveAfterMidnight() throws {
        let model = AppModel.withTestCard()
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        model.setCaptureDateFilter(.today(anchor: anchor), for: model.cards[0])

        let first = try #require(model.cards[0].capturedIn)
        model.setCaptureDateFilter(.today(anchor: anchor), for: model.cards[0])
        let second = try #require(model.cards[0].capturedIn)

        #expect(first == second)
    }

    @Test func singleDayBuildsWholeDayInterval() throws {
        let model = AppModel.withTestCard()
        let date = Date(timeIntervalSince1970: 1_780_123_456)
        model.setCaptureDateFilter(.singleDay(date), for: model.cards[0])

        let interval = try #require(model.cards[0].capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: date)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    @Test func rangeNormalizesBeforeDateInterval() throws {
        let model = AppModel.withTestCard()
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        let last = first.addingTimeInterval(2 * 86_400)
        model.setCaptureDateFilter(.range(start: last, end: first), for: model.cards[0])

        let interval = try #require(model.cards[0].capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: first)
        let expectedLastStart = cal.startOfDay(for: last)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedLastStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    /// O filtro de data é de cada cartão: outro cartão começa sem filtro.
    @Test func changingCardClearsTemporaryFilter() {
        let model = AppModel()
        let first = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD-A"),
                                   name: "CARD-A", isRemovable: true, isInternal: false)
        let second = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD-B"),
                                    name: "CARD-B", isRemovable: true, isInternal: false)

        model.watcher.volumes = [first]
        model.forcedSources = [first.id]
        model.reconcileVolumes()
        model.setCaptureDateFilter(.singleDay(Date(timeIntervalSince1970: 1_780_000_000)), for: model.selectedCard!)
        #expect(model.selectedCard?.captureDateFilter != .all)

        model.watcher.volumes = [second]
        model.forcedSources = [second.id]
        model.reconcileVolumes()

        #expect(model.selectedCard?.volume.name == "CARD-B")
        #expect(model.selectedCard?.captureDateFilter == .all)
    }
}
