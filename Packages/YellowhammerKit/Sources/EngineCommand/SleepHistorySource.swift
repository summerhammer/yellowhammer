import Darwin
import Foundation
import Subprocess
import System

/// The macOS sleep/wake log seam `yh status` correlates against a Night's firing instants (spec's
/// Surface 3). Tests inject a stub; `StatusCommand` builds ``PmsetSleepHistory``.
protocol SleepHistorySource: Sendable {
    /// The Mac's sleep/wake history, or nil on any failure (missing binary, non-zero exit, unparseable
    /// output) — `yh status` reports "sleep history unavailable" rather than failing the whole command.
    func sleepHistory() async -> SleepHistory?
}

/// Runs `/usr/bin/pmset -g log` and parses its sleep/wake log into a ``SleepHistory``.
struct PmsetSleepHistory: SleepHistorySource {
    let pmsetPath: String
    /// `pmset -g log` output can run to several megabytes on a Mac that has not rebooted in a while;
    /// a generous cap keeps a pathological log from exhausting memory instead of just failing to parse.
    private static let outputLimit = 64 * 1024 * 1024

    init(pmsetPath: String = "/usr/bin/pmset") {
        self.pmsetPath = pmsetPath
    }

    func sleepHistory() async -> SleepHistory? {
        guard
            let result = try? await Subprocess.run(
                .path(FilePath(pmsetPath)), arguments: Arguments(["-g", "log"]),
                output: .string(limit: Self.outputLimit), error: .discarded
            ),
            case .exited(0) = result.terminationStatus
        else { return nil }
        return Self.parse(result.standardOutput)
    }

    /// One timestamped `pmset -g log` line's fixed-width date (`yyyy-MM-dd HH:mm:ss Z`, 25 characters)
    /// followed by a space, then the event type padded with spaces up to a TAB.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parses `pmset -g log` text into a ``SleepHistory``: `Sleep` opens an interval (if not already
    /// asleep), `Wake` and `Start` (boot) close it. `DarkWake` does not close it — a dark wake is a
    /// seconds-long maintenance wake, and the Mac stays asleep from the Operator's view. Every other
    /// event type (`Wake Requests`, `WakeDetails`, `WakeTime`, `Assertions`, `SleepAborted`, ...) is
    /// ignored. An interval still open at the end of the log is dropped — we are awake now, so the log
    /// is simply truncated, not still asleep. Returns nil when the text carries no timestamped line.
    static func parse(_ text: String) -> SleepHistory? {
        var intervals: [SleepInterval] = []
        var openSince: Date?
        var coverageStart: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let event = parseLine(line) else { continue }
            if coverageStart == nil { coverageStart = event.date }

            switch event.type {
            case "Sleep":
                if openSince == nil { openSince = event.date }
            case "Wake", "Start":
                if let start = openSince {
                    intervals.append(SleepInterval(start: start, end: event.date))
                    openSince = nil
                }
            default:
                break
            }
        }

        guard let coverageStart else { return nil }
        return SleepHistory(intervals: intervals, coverageStart: coverageStart)
    }

    /// One line's timestamp and event type, or nil when the line carries no timestamp (a continuation
    /// or detail line the log intersperses between events).
    private static func parseLine(_ line: Substring) -> (date: Date, type: String)? {
        guard line.count > 26 else { return nil }
        guard let date = dateFormatter.date(from: String(line.prefix(25))) else { return nil }
        guard let tabIndex = line.firstIndex(of: "\t") else { return nil }
        let afterDate = line.index(line.startIndex, offsetBy: 26)
        guard afterDate <= tabIndex else { return nil }
        let type = line[afterDate..<tabIndex].trimmingCharacters(in: .whitespaces)
        return (date, type)
    }
}
