import AppKit
import Config
import Domain
import SwiftUI

/// The Recalibrate tab (P14.7): this Project's Bounds and this Night's proximity to each, re-setting a
/// Bound's value, and starting a rehearsal Night. The app never computes proximity or runs a Night
/// itself — `yh recalibrate` and `yh rehearse` do; this tab only shells them and displays.
struct RecalibrateView: View {
    @State private var model: RecalibrateModel

    init(project: ProjectID) {
        _model = State(initialValue: RecalibrateModel(project: project))
    }

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

    /// The six Bounds, in the order the Configuration tab's form declares them (P14.3), paired with the
    /// ``BoundsDraft`` field each edits.
    private static let boundFields: [(key: String, keyPath: WritableKeyPath<BoundsDraft, String>)] = [
        ("review_rounds_max", \BoundsDraft.reviewRoundsMax),
        ("attempts_per_card", \BoundsDraft.attemptsPerCard),
        ("unanswered_nights_max", \BoundsDraft.unansweredNightsMax),
        ("reselections_max", \BoundsDraft.reselectionsMax),
        ("consecutive_refusals_max", \BoundsDraft.consecutiveRefusalsMax),
        ("failed_adoptions_max", \BoundsDraft.failedAdoptionsMax)
    ]

    var body: some View {
        if let current = model.detail.draft {
            let draft = Binding(get: { model.detail.draft ?? current }, set: { model.detail.draft = $0 })
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        nightHeader
                        boundsTable(draft)
                        rehearsalSection
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        } else {
            Text(model.detail.loadFailure ?? "This Project could not be loaded.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding()
        }
    }

    @ViewBuilder private var nightHeader: some View {
        if let night = model.report?.night {
            Text("This Night: \(night.nightStart) (\(night.mode))")
                .font(.headline)
                .accessibilityIdentifier("recalibrate-night-header")
        } else if model.report != nil {
            Text("No Night recorded")
                .font(.headline)
                .accessibilityIdentifier("recalibrate-night-header")
        } else if !model.rawOutputLines.isEmpty {
            Text(model.rawOutputLines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("recalibrate-raw-output")
        }
    }

    @ViewBuilder
    private func boundsTable(_ draft: Binding<ProjectFileDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.boundFields, id: \.key) { field in
                boundRow(draft, key: field.key, keyPath: field.keyPath)
            }
        }
    }

    @ViewBuilder
    private func boundRow(
        _ draft: Binding<ProjectFileDraft>, key: String, keyPath: WritableKeyPath<BoundsDraft, String>
    ) -> some View {
        let reading = model.report?.bounds.first(where: { $0.name == key })
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(reading?.consequence ?? "\u{2014}")
                .frame(width: 240, alignment: .leading)
                .accessibilityIdentifier("recalibrate-consequence-\(key)")
            TextField(key, text: draft.bounds[dynamicMember: keyPath])
                .frame(width: 60)
                .accessibilityIdentifier("recalibrate-value-\(key)")
            Text(proximityText(reading))
                .frame(width: 160, alignment: .leading)
                .accessibilityIdentifier("recalibrate-proximity-\(key)")
            Text(key)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recalibrate-name-\(key)")
        }
    }

    private func proximityText(_ reading: RecalibrateReport.BoundReading?) -> String {
        guard let reading, let proximity = reading.proximity else { return "no Night recorded" }
        return "\(proximity) of \(reading.value)"
    }

    private var rehearsalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let note = model.rehearsalStartedNote {
                HStack(spacing: 8) {
                    Text(note)
                        .accessibilityIdentifier("recalibrate-rehearsal-started")
                    if let logURL = model.rehearsalLogURL {
                        Button("Show Log") { NSWorkspace.shared.open(logURL) }
                            .accessibilityIdentifier("recalibrate-show-log")
                    }
                }
            }
            if let failure = model.rehearsalFailure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("recalibrate-rehearsal-failure")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.detail.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("recalibrate-save-failure")
            }
            HStack {
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.detail.isDirty)
                    .accessibilityIdentifier("recalibrate-revert")
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.detail.isDirty)
                    .accessibilityIdentifier("recalibrate-save")
            }
        }
        .padding()
    }
}
