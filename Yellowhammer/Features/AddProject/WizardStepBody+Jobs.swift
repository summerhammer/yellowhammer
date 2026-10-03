import Config
import SwiftUI

/// The scheduled jobs configuration: when the Night runs and whether launchd's three LaunchAgents are
/// installed, exported to a folder as launchd or cron entries, or not generated now.
struct JobsSections: View {
    @Binding var draft: AddProjectDraft

    private static let times = (0..<24).compactMap { TimeOfDay(hour: $0, minute: 0) }

    var body: some View {
        Section(
            header: Text("The Night"),
            footer: Text(
                "The Night window is per Project. The LaunchAgents are generated from it when setup runs."
            )
            .foregroundStyle(.secondary)
        ) {
            Picker("Starts", selection: $draft.schedule.nightStart) {
                ForEach(Self.times, id: \.self) { Text($0.description).tag($0) }
            }
            .accessibilityIdentifier("setup-night-start")
            Picker("Ends", selection: $draft.schedule.nightEnd) {
                ForEach(Self.times, id: \.self) { Text($0.description).tag($0) }
            }
            .accessibilityIdentifier("setup-night-end")
            Stepper(value: $draft.schedule.buildEveryMinutes, in: 5...120, step: 5) {
                LabeledContent("Build every", value: "\(draft.schedule.buildEveryMinutes) min")
            }
            .accessibilityIdentifier("setup-build-every")
        }
        Section(
            header: Text("Scheduled jobs"), // glossary:ignore GL001
            footer: Text(
                "launchd runs author, build and land for this Project. The Night runs with the app quit."
            )
            .foregroundStyle(.secondary)
        ) {
            Picker("Scheduled jobs", selection: $draft.jobs) { // glossary:ignore GL001
                Text("Install the three LaunchAgents").tag(AddProjectDraft.JobsChoice.install)
                Text("Export to a folder").tag(AddProjectDraft.JobsChoice.export)
                Text("Not now").tag(AddProjectDraft.JobsChoice.notNow)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("setup-jobs-picker")
            if draft.jobs == .export {
                LabeledContent("Folder") {
                    HStack {
                        Text(draft.exportDirectory.isEmpty ? "None" : draft.exportDirectory)
                            .font(.body.monospaced())
                            .foregroundStyle(draft.exportDirectory.isEmpty ? .secondary : .primary)
                        Button("Choose…") {
                            guard let url = SetupWizardModel.chooseFolder() else { return }
                            draft.exportDirectory = url.path(percentEncoded: false)
                        }
                    }
                }
                Picker("Format", selection: $draft.exportUsesCron) {
                    Text("launchd").tag(false)
                    Text("cron").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        let problems = draft.problems(in: .jobs)
        if !problems.isEmpty {
            Section {
                WizardProblemList(problems: problems)
            }
        }
    }
}
