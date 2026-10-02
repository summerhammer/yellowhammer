import Config
import SwiftUI

/// The scheduled jobs configuration: when the Night runs and whether launchd's three LaunchAgents are
/// installed, exported to a folder as launchd or cron entries, or not generated now.
struct JobsSections: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        let schedule = Schedule()
        Section(
            header: Text("The Night"),
            footer: Text("Every Project starts with these defaults.").foregroundStyle(.secondary)
        ) {
            LabeledContent("Starts", value: schedule.nightStart.description)
            LabeledContent("Ends", value: schedule.nightEnd.description)
            LabeledContent("Build every", value: "\(schedule.buildEveryMinutes) min")
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
