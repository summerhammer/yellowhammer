@testable import EngineCommand
import Foundation
import Testing

@Suite("pmset -g log parser")
struct SleepHistorySourceTests {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func date(_ text: String) -> Date {
        formatter.date(from: text)!
    }

    /// One `pmset -g log` line: a fixed-width date, a space, the event type padded to a TAB, then
    /// whatever detail text follows.
    private static func line(_ dateText: String, _ type: String, detail: String = "detail") -> String {
        "\(dateText) \(type)               \t\(detail)"
    }

    @Test("Sleep then Wake produces one interval")
    func sleepThenWake() {
        let text = [
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-23 07:10:00 +0000", "Wake")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.coverageStart == Self.date("2026-09-22 21:40:00 +0000"))
        #expect(history?.intervals == [
            SleepInterval(start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000"))
        ])
    }

    @Test("Start (boot) also closes a sleep interval")
    func startClosesInterval() {
        let text = [
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-23 07:10:00 +0000", "Start")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.intervals == [
            SleepInterval(start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000"))
        ])
    }

    @Test("DarkWake does not close the sleep interval")
    func darkWakeDoesNotClose() {
        let text = [
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-22 23:00:00 +0000", "DarkWake"),
            Self.line("2026-09-23 07:10:00 +0000", "Wake")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.intervals == [
            SleepInterval(start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000"))
        ])
    }

    @Test("Wake Requests, WakeDetails, WakeTime, Assertions and SleepAborted are ignored")
    func ignoredEventTypes() {
        let text = [
            Self.line("2026-09-22 21:00:00 +0000", "Wake Requests"),
            Self.line("2026-09-22 21:10:00 +0000", "WakeDetails"),
            Self.line("2026-09-22 21:20:00 +0000", "WakeTime"),
            Self.line("2026-09-22 21:30:00 +0000", "Assertions"),
            Self.line("2026-09-22 21:35:00 +0000", "SleepAborted"),
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-23 07:10:00 +0000", "Wake")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.coverageStart == Self.date("2026-09-22 21:00:00 +0000"))
        #expect(history?.intervals == [
            SleepInterval(start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000"))
        ])
    }

    @Test("A trailing open Sleep with no closing Wake is dropped")
    func trailingOpenSleepDropped() {
        let text = [
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-23 07:10:00 +0000", "Wake"),
            Self.line("2026-09-23 21:40:00 +0000", "Sleep")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.intervals == [
            SleepInterval(start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000"))
        ])
    }

    @Test("No timestamped line parses to nil")
    func noTimestampedLineParsesToNil() {
        #expect(PmsetSleepHistory.parse("garbage\nmore garbage\n") == nil)
    }

    @Test("coverageStart is the first timestamped line's date, before any Sleep/Wake")
    func coverageStartIsFirstTimestamp() {
        let text = [
            Self.line("2026-09-20 00:00:00 +0000", "Assertions"),
            Self.line("2026-09-22 21:40:00 +0000", "Sleep"),
            Self.line("2026-09-23 07:10:00 +0000", "Wake")
        ].joined(separator: "\n")

        let history = PmsetSleepHistory.parse(text)
        #expect(history?.coverageStart == Self.date("2026-09-20 00:00:00 +0000"))
    }
}
