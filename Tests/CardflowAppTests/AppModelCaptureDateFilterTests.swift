import Foundation
import Testing
@testable import OffloadKit
@testable import CardflowApp

@MainActor
@Suite struct AppModelCaptureDateFilterTests {
    @Test func defaultFilterCopiesAllFiles() {
        let model = AppModel()
        #expect(model.captureDateFilter == .all)
        #expect(model.capturedIn == nil)
    }

    @Test func todayUsesAnchorDay() throws {
        let model = AppModel()
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        model.captureDateFilter = .today(anchor: anchor)

        let interval = try #require(model.capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: anchor)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    @Test func todayAnchorDoesNotMoveAfterMidnight() throws {
        let model = AppModel()
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        model.captureDateFilter = .today(anchor: anchor)

        let first = try #require(model.capturedIn)
        model.captureDateFilter = .today(anchor: anchor)
        let second = try #require(model.capturedIn)

        #expect(first == second)
    }

    @Test func singleDayBuildsWholeDayInterval() throws {
        let model = AppModel()
        let date = Date(timeIntervalSince1970: 1_780_123_456)
        model.captureDateFilter = .singleDay(date)

        let interval = try #require(model.capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: date)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    @Test func rangeNormalizesBeforeDateInterval() throws {
        let model = AppModel()
        let first = Date(timeIntervalSince1970: 1_780_000_000)
        let last = first.addingTimeInterval(2 * 86_400)
        model.captureDateFilter = .range(start: last, end: first)

        let interval = try #require(model.capturedIn)
        let cal = Calendar.current
        let expectedStart = cal.startOfDay(for: first)
        let expectedLastStart = cal.startOfDay(for: last)
        let expectedEnd = try #require(cal.date(byAdding: .day, value: 1, to: expectedLastStart))

        #expect(interval.start == expectedStart)
        #expect(interval.end == expectedEnd)
    }

    @Test func changingCardClearsTemporaryFilter() {
        let model = AppModel()
        let first = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD-A"),
                                   name: "CARD-A", isRemovable: true, isInternal: false)
        let second = ExternalVolume(url: URL(fileURLWithPath: "/Volumes/CARD-B"),
                                    name: "CARD-B", isRemovable: true, isInternal: false)

        model.watcher.volumes = [first]
        model.forcedSources = [first.id]
        model.selectedCardURL = first.url
        model.refreshCardPreview()

        model.captureDateFilter = .singleDay(Date(timeIntervalSince1970: 1_780_000_000))

        model.watcher.volumes = [second]
        model.forcedSources = [second.id]
        model.selectedCardURL = second.url
        model.refreshCardPreview()

        #expect(model.captureDateFilter == .all)
    }
}
