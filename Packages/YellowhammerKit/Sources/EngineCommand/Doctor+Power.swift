import Foundation
import Subprocess
import System

/// One power source's system `sleep` timer, as `pmset -g custom` prints it.
struct PowerSourceSleep: Equatable, Sendable {
    /// The phrase that completes "<phrase> this Mac sleeps ...": `on battery`, `on AC power`, `on UPS power`.
    let source: String
    /// Minutes of idle before the Mac sleeps; 0 means never.
    let minutes: Int
}

/// The power-settings seam the power check reads. Tests inject a fake; `Doctor` defaults to ``PmsetPowerSettings``.
protocol PowerSettingsReading: Sendable {
    /// Every power source's `sleep` timer, or nil when the settings could not be read.
    func sleepTimers() async -> [PowerSourceSleep]?
}

/// Runs `/usr/bin/pmset -g custom` and parses the system `sleep` key of every power source.
struct PmsetPowerSettings: PowerSettingsReading {
    let pmsetPath: String
    private static let outputLimit = 1024 * 1024

    init(pmsetPath: String = "/usr/bin/pmset") {
        self.pmsetPath = pmsetPath
    }

    func sleepTimers() async -> [PowerSourceSleep]? {
        guard
            let result = try? await Subprocess.run(
                .path(FilePath(pmsetPath)), arguments: Arguments(["-g", "custom"]),
                output: .string(limit: Self.outputLimit), error: .discarded
            ),
            case .exited(0) = result.terminationStatus
        else { return nil }
        return Self.parse(result.standardOutput)
    }

    /// Parses `pmset -g custom` text: a header at column 0 opens a power source, and its indented
    /// `key value` lines follow. Only the exact `sleep` key counts (never `displaysleep` or `disksleep`),
    /// and its value is the first integer token, so `sleep 1 (sleep prevented by ...)` reads as 1.
    /// Returns nil when no source carries a `sleep` line.
    static func parse(_ text: String) -> [PowerSourceSleep]? {
        var timers: [PowerSourceSleep] = []
        var source: String?
        var seenSleep = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let first = line.first, !first.isWhitespace {
                source = phrase(forHeader: line)
                seenSleep = false
                continue
            }
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let source, !seenSleep, tokens.count >= 2, tokens[0] == "sleep",
                  let minutes = Int(tokens[1])
            else { continue }
            seenSleep = true
            timers.append(PowerSourceSleep(source: source, minutes: minutes))
        }
        return timers.isEmpty ? nil : timers
    }

    private static func phrase(forHeader header: Substring) -> String {
        let name = header.trimmingCharacters(in: CharacterSet(charactersIn: ": \t\r"))
        switch name {
        case "Battery Power": return "on battery"
        case "AC Power": return "on AC power"
        case "UPS Power": return "on UPS power"
        default: return "on \(name)"
        }
    }
}

extension Doctor {
    /// Check 9, last: warn when a power source lets the Mac sleep. It diagnoses an unmet prerequisite; it
    /// never fails and does not compensate for sleep.
    func runPowerCheck() async -> [DoctorFinding] {
        guard let timers = await powerSettings.sleepTimers() else {
            return [finding(.power, subject: "power settings", .warning, "the power settings could not be read")]
        }
        let sleeping = timers.filter { $0.minutes != 0 }
        guard !sleeping.isEmpty else {
            return [finding(
                .power, subject: "power settings", .pass,
                "this Mac never sleeps on any power source; this check cannot see a closed lid and cannot know "
                    + "which power source the Mac will be on overnight, so a clean check promises nothing"
            )]
        }
        return sleeping.map { timer in
            finding(
                .power, subject: timer.source, .warning,
                "\(timer.source) this Mac sleeps after \(timer.minutes) min; a Night needs it awake"
            )
        }
    }
}
