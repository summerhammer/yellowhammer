import Domain
import SwiftUI

/// The Status tab of a Project window (P14.6; OQ12 Surface 3): the app equivalent of `yh status` and
/// `yh doctor` for this window's Project. Runs both on demand and shows their output verbatim — the app
/// displays, it never decides: no fix, remove, reinstall or triage control lives here. Every decision
/// belongs to Linear or the CLI.
struct ProjectStatusView: View {
    @State private var model: ProjectStatusModel

    init(project: ProjectID) {
        _model = State(initialValue: ProjectStatusModel(project: project))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(SectionSpec(
                    title: "Status", lines: model.statusLines, exitStatus: model.statusExitStatus,
                    command: "yh status", logIdentifier: "project-status-status-log",
                    exitStatusIdentifier: "project-status-status-exit-status", colorizeDoctor: false
                ))
                section(SectionSpec(
                    title: "Doctor", lines: model.doctorLines, exitStatus: model.doctorExitStatus,
                    command: "yh doctor", logIdentifier: "project-status-doctor-log",
                    exitStatusIdentifier: "project-status-doctor-exit-status", colorizeDoctor: true
                ))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .accessibilityIdentifier("project-status-refresh")
                }
            }
        }
        .task { await model.refresh() }
    }

    /// One output section's display parameters, grouped to keep ``section(_:)`` under the lint's
    /// parameter-count limit.
    private struct SectionSpec {
        let title: String
        let lines: [String]
        let exitStatus: Int32?
        let command: String
        let logIdentifier: String
        let exitStatusIdentifier: String
        let colorizeDoctor: Bool
    }

    @ViewBuilder
    private func section(_ spec: SectionSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec.title)
                .font(.headline)
            let joined = spec.lines.joined(separator: "\n")
            Text(spec.colorizeDoctor ? doctorAttributed(spec.lines) : AttributedString(joined))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(spec.logIdentifier)
                .accessibilityValue(joined)
            if let exitStatus = spec.exitStatus, exitStatus != 0 {
                Text("\(spec.command) exited with status \(exitStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(spec.exitStatusIdentifier)
            }
        }
    }

    /// `yh doctor`'s output, colored per line: `[FAIL]` red, `[warn]` orange, everything else the
    /// default text color. The accessibility value stays the plain joined text via `.accessibilityValue`
    /// above, so a UI test can read it regardless of this coloring.
    private func doctorAttributed(_ lines: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var segment = AttributedString(line)
            if line.hasPrefix("[FAIL]") {
                segment.foregroundColor = .red
            } else if line.hasPrefix("[warn]") {
                segment.foregroundColor = .orange
            }
            result += segment
            if index < lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }
}
