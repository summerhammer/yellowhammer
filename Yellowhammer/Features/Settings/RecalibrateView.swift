import AppKit
import Config
import Domain
import SwiftUI

/// The Recalibrate tab (P14.7): this Project's Bounds and this Night's proximity to each, re-setting a
/// Bound's value, and starting a rehearsal Night. The app never computes proximity or runs a Night
/// itself — `yh recalibrate` and `yh rehearse` do; this tab only shells them and displays.
struct RecalibrateView: View {
    /// Owned by the Project's pane, so moving to Configuration and back keeps an unsaved Bound.
    let model: RecalibrateModel

    var body: some View {
        RecalibrateContentView(model: model)
            .toolbar {
                ToolbarItem {
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .accessibilityIdentifier("recalibrate-refresh")
                    }
                }
            }
            .task { await model.refresh() }
    }
}

/// Split out so it always runs against a live model reference.
private struct RecalibrateContentView: View {
    @Bindable var model: RecalibrateModel
    @State private var showingRehearsalConfirmation = false

    var body: some View {
        if let current = model.detail.draft {
            let draft = Binding(get: { model.detail.draft ?? current }, set: { model.detail.draft = $0 })
            SettingsPane {
                nightBlock
                boundsBlock(draft)
                rehearsalBlock
            } footer: {
                SettingsSaveFooter(
                    failure: model.detail.failure,
                    isDirty: model.detail.isDirty,
                    identifierPrefix: "recalibrate",
                    onRevert: { model.revert() },
                    onSave: { model.save() }
                )
            }
        } else {
            SettingsUnavailable(message: model.detail.loadFailure ?? "This Project could not be loaded.")
        }
    }

    @ViewBuilder private var nightBlock: some View {
        WizardBlock(title: "This Night") {
            if let night = model.report?.night {
                WizardBlockRow(label: "Started") {
                    Text("\(night.nightStart) (\(night.mode))")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recalibrate-night-header")
                }
            } else if model.report != nil {
                Text("No Night recorded")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .accessibilityIdentifier("recalibrate-night-header")
            } else if !model.rawOutputLines.isEmpty {
                Text(model.rawOutputLines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("recalibrate-raw-output")
            } else if model.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading this Night\u{2026}").foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                Text("yh recalibrate printed nothing.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    /// Each Bound as `yh recalibrate` words its consequence, this Night's proximity to it, and its value.
    private func boundsBlock(_ draft: Binding<ProjectFileDraft>) -> some View {
        WizardBlock(
            title: "Bounds",
            footer: "How close this Night came to each Bound, as yh recalibrate reports it. Saving re-sets the "
                + "Project\u{2019}s Bounds."
        ) {
            ForEach(Bounds.fields, id: \.key) { field in
                if let keyPath = BoundsDraft.keyPath(for: field.key) {
                    boundRow(field, text: draft.bounds[dynamicMember: keyPath])
                }
                if field.key != Bounds.fields.last?.key {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private func boundRow(_ field: Bounds.Field, text: Binding<String>) -> some View {
        let reading = model.report?.bounds.first(where: { $0.name == field.key })
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(reading?.consequence ?? field.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recalibrate-consequence-\(field.key)")
                Text(field.key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recalibrate-name-\(field.key)")
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("This Night").font(.caption).foregroundStyle(.secondary)
                Text(proximityText(reading))
                    .monospacedDigit()
                    .accessibilityIdentifier("recalibrate-proximity-\(field.key)")
            }
            BoundValueField(text: text, field: field, identifier: "recalibrate-value-\(field.key)")
        }
        .padding(12)
    }

    private func proximityText(_ reading: RecalibrateReport.BoundReading?) -> String {
        guard let reading, let proximity = reading.proximity else { return "no Night recorded" }
        return "\(proximity) of \(reading.value)"
    }

    private var rehearsalBlock: some View {
        WizardBlock(
            title: "Rehearsal Night",
            footer: "A rehearsal never dispatches an agent CLI, never pushes and never opens a pull request. "
                + "Its board writes to this Project\u{2019}s Linear project are real."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Runs this Project\u{2019}s author, build and land Acts in rehearsal mode.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    rehearsalButton
                }
                if let note = model.rehearsalStartedNote {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.success)
                            .accessibilityHidden(true)
                        Text(note)
                            .accessibilityIdentifier("recalibrate-rehearsal-started")
                        Spacer()
                        if let logURL = model.rehearsalLogURL {
                            Button("Show Log") { NSWorkspace.shared.open(logURL) }
                                .accessibilityIdentifier("recalibrate-show-log")
                        }
                    }
                }
                if let failure = model.rehearsalFailure {
                    SettingsFailureText(text: failure, identifier: "recalibrate-rehearsal-failure")
                }
            }
            .padding(12)
        }
    }

    private var rehearsalButton: some View {
        Button("Run a Rehearsal Night\u{2026}") { showingRehearsalConfirmation = true }
            .disabled(model.isLaunchingRehearsal)
            .accessibilityIdentifier("recalibrate-run-rehearsal")
            .confirmationDialog(
                "Run a Rehearsal Night?",
                isPresented: $showingRehearsalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Run Rehearsal Night") { model.confirmRehearsal() }
                    .accessibilityIdentifier("recalibrate-confirm-rehearsal")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Runs this Project\u{2019}s author, build and land Acts in rehearsal mode. It "
                        + "never dispatches an agent CLI, never pushes and never opens a pull "
                        + "request. Its board writes to this Project\u{2019}s Linear project are "
                        + "real. It keeps running if the app quits."
                )
            }
    }
}
