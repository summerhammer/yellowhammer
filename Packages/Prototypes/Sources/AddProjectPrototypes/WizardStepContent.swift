#if DEBUG
import SwiftUI

// What Hub4 shares between its steps: the Scheduled jobs form, the run's outcome, and the small parts
// around them. The other steps' fields are in `WizardStepBody.swift`.

extension EnvironmentValues {
    /// Every way out of the sheet (Cancel, Done, Close). The Playground records each call.
    @Entry var addProjectAction: @MainActor (String) -> Void = { _ in }
}

// MARK: - Scheduled jobs

struct JobsSections: View {
    @Binding var draft: AddProjectDraft

    private static let times = (0..<24).map { String(format: "%02d:00", $0) }

    var body: some View {
        Section("The Night") {
            Picker("Starts", selection: $draft.nightStart) {
                ForEach(Self.times, id: \.self) { Text($0).tag($0) }
            }
            Picker("Ends", selection: $draft.nightEnd) {
                ForEach(Self.times, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $draft.buildEveryMinutes, in: 5...120, step: 5) {
                LabeledContent("Build every", value: "\(draft.buildEveryMinutes) min")
            }
        }
        Section {
            Picker("Scheduled jobs", selection: $draft.jobs) { // glossary:ignore GL001
                Text("Install the three LaunchAgents").tag(JobsChoice.install)
                Text("Export to a folder").tag(JobsChoice.export)
                Text("Not now").tag(JobsChoice.notNow)
            }
            .pickerStyle(.radioGroup)
            if draft.jobs == .export {
                LabeledContent("Folder") {
                    HStack {
                        Text(draft.exportDirectory.isEmpty ? "None" : draft.exportDirectory)
                            .font(.body.monospaced())
                            .foregroundStyle(draft.exportDirectory.isEmpty ? .secondary : .primary)
                        Button("Choose…") { draft.chooseExportDirectory() }
                    }
                }
                Picker("Format", selection: $draft.exportUsesCron) {
                    Text("launchd").tag(false)
                    Text("cron").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Scheduled jobs") // glossary:ignore GL001
        } footer: {
            Text("launchd runs author, build and land for this Project. The Night runs with the app quit.")
                .foregroundStyle(.secondary)
        }
        if !draft.problems(in: .jobs).isEmpty {
            Section { WizardProblemList(problems: draft.problems(in: .jobs)) }
        }
    }
}

// MARK: - Run

/// The last screen: the fixture run's log and its outcome.
struct WizardRunView: View {
    let draft: AddProjectDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch draft.run {
            case .notStarted, .running:
                ProgressView("Adding \(draft.displayName)…")
            case .succeeded:
                Label("\(draft.displayName) is added", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WizardTheme.success)
                Text("Its first Night starts at \(draft.nightStart). Change it later in Settings.")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Setup failed", systemImage: "xmark.octagon.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WizardTheme.error)
                Text("The log below explains it. The Project file may already be written; Settings lists it.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(draft.runLog.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 8))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Small parts

/// A step's problems in `error`.
struct WizardProblemList: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(WizardTheme.error)
            }
        }
    }
}

/// The footer's bottom-right once a run has started: Done and Close.
struct WizardNavigationButtons: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    var body: some View {
        switch draft.run {
        case .succeeded:
            Button("Done") { action("Done — select \(draft.displayName) in the Sidebar") }
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Back to Review") { draft.run = .notStarted }
            Button("Close") { action("Close after a failed run") }
                .keyboardShortcut(.defaultAction)
        case .notStarted, .running:
            if !draft.isFirstStep {
                Button("Back") { draft.goBack() }
            }
            Button(draft.continueTitle) { draft.goForward() }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canContinue)
        }
    }
}

/// Cancel, which writes nothing.
struct WizardCancelButton: View {
    var caption = true
    @Environment(\.addProjectAction) private var action

    var body: some View {
        Button("Cancel") { action("Cancel — leaves nothing behind") }
            .keyboardShortcut(.cancelAction)
        if caption {
            Text("leaves nothing behind").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Binding where Value == AddProjectDraft {
    /// A binding to one Repo by id, safe against the Repo being removed mid-render.
    func repo(_ id: RepoDraft.ID) -> Binding<RepoDraft> {
        Binding<RepoDraft> {
            wrappedValue.repos.first { $0.id == id } ?? RepoDraft(path: "")
        } set: { newValue in
            guard let index = wrappedValue.repos.firstIndex(where: { $0.id == id }) else { return }
            wrappedValue.repos[index] = newValue
        }
    }
}
#endif
