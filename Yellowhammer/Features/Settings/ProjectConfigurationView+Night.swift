import Config
import SwiftUI

extension ProjectConfigurationFormView {
    /// The Night's start, end and build interval, as typed. Each value reaches the loader as typed, so a
    /// value it refuses is shown in its words by the form's Save footer.
    func nightBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        WizardBlock(
            title: "The Night",
            footer: "Saving a changed Night regenerates this Project\u{2019}s installed LaunchAgents. "
                + "Exported launchd or cron files must be exported again."
        ) {
            WizardBlockRow(label: "Starts") {
                NightTimeField(text: draft.schedule.nightStart, fallback: Schedule().nightStart)
                    .accessibilityIdentifier("project-night-start") // glossary:ignore GL001
            }
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "Ends") {
                NightTimeField(text: draft.schedule.nightEnd, fallback: Schedule().nightEnd)
                    .accessibilityIdentifier("project-night-end") // glossary:ignore GL001
            }
            Divider().padding(.leading, 12)
            WizardBlockRow(label: "Build every") {
                BuildIntervalField(text: draft.schedule.buildEveryMinutes)
            }
            if model.isRegeneratingJobs || model.jobsRegenerationResult != nil
                || model.jobsRegenerationFailure != nil {
                Divider().padding(.leading, 12)
                regenerationStatus
            }
        }
    }

    @ViewBuilder private var regenerationStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isRegeneratingJobs { ProgressView("Regenerating LaunchAgents\u{2026}") }
            if let result = model.jobsRegenerationResult {
                Text(result).textSelection(.enabled)
                    .accessibilityIdentifier("project-night-regenerated") // glossary:ignore GL001
            }
            if let failure = model.jobsRegenerationFailure {
                Text(failure).textSelection(.enabled)
                    .accessibilityIdentifier("project-night-regeneration-failure") // glossary:ignore GL001
            }
        }
        .padding(12)
    }
}

/// An `HH:MM` string edited with a time picker. A string the picker cannot show (a typo from a hand edit)
/// shows `fallback` until the Operator picks a time; untouched, it is saved as it was.
private struct NightTimeField: View {
    @Binding var text: String
    let fallback: TimeOfDay

    var body: some View {
        DatePicker("Time", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            // The picker draws in its environment's zone; left at the Mac's, a stored 20:00 showed as 22:00.
            .environment(\.timeZone, Self.calendar.timeZone)
            .environment(\.calendar, Self.calendar)
    }

    /// A fixed calendar and zone, so the picker's hour and minute are the stored ones and never shift.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private var date: Binding<Date> {
        Binding {
            let time = TimeOfDay(text.trimmed) ?? fallback
            return Self.calendar.date(from: DateComponents(
                year: 2001, month: 1, day: 1, hour: time.hour, minute: time.minute
            )) ?? Date(timeIntervalSinceReferenceDate: 0)
        } set: { newValue in
            let parts = Self.calendar.dateComponents([.hour, .minute], from: newValue)
            if let time = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0) {
                text = time.description
            }
        }
    }
}

/// The build interval in minutes: a typed field, so a value the loader refuses still reaches it, with a
/// stepper that steps from the typed number or from the default while the field holds something else.
private struct BuildIntervalField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("Build every", text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
                .accessibilityIdentifier("project-build-every") // glossary:ignore GL001
            Stepper("Build every", value: value, in: 1...1440)
                .labelsHidden()
            Text("min").foregroundStyle(.secondary)
        }
    }

    private var value: Binding<Int> {
        Binding {
            Int(text.trimmed) ?? Schedule().buildEveryMinutes
        } set: { newValue in
            text = String(newValue)
        }
    }
}
