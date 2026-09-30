#if DEBUG
import Domain
import SwiftUI

// The Sidebar's row styles. Every style keeps the tree Project → every Repo (always shown, in
// `[repos]` order) → the running Attempt, in configured order, and derives each value from that one
// Project's own Pulse. Repo and Attempt rows are selectable like Project rows: selecting one selects
// its Project and opens it in the Inspector.

enum PulseSidebarRows: String, CaseIterable {
    /// The Baseline's rows tidied: status text trailing, lane badges as capsules.
    case sourceList
    /// A status dot per Project, a Needs you count badge, and lane state as a dot.
    case badged
    /// Two-line Project rows carrying the Now line, like Mail's message list.
    case twoLine
}

/// A Sidebar row's identity. Repos are unique machine-wide (a Repo belongs to exactly one Project),
/// but the tag still names its Project so selecting it can scope the Pulse.
enum PulseSidebarTag: Hashable {
    case project(ProjectID)
    case repo(ProjectID, String)
    case attempt(ProjectID, String)

    var projectID: ProjectID {
        switch self {
        case let .project(id), let .repo(id, _), let .attempt(id, _): id
        }
    }
}

struct PulseSidebarList: View {
    let snapshot: LandingSnapshot
    @Binding var selection: ProjectID?
    let rows: PulseSidebarRows
    let actions: PulseActions
    @State private var rowSelection: PulseSidebarTag?
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        // One flat ForEach with exactly one view per element: a sidebar List on macOS traps when a
        // ForEach element yields a varying number of rows (the optional Attempt row did that).
        List(selection: tagSelection) {
            Section("Projects") {
                ForEach(treeRows) { row in
                    switch row.kind {
                    case .project:
                        projectRow(row.project)
                    case let .repo(repo):
                        repoRow(repo, in: row.project).padding(.leading, 18)
                    case let .attempt(attempt):
                        attemptRow(attempt).padding(.leading, 36)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// One Sidebar row. Its `id` is its selection tag.
    private struct TreeRow: Identifiable {
        let project: ProjectSnapshot
        let kind: TreeRowKind

        var id: PulseSidebarTag {
            switch kind {
            case .project: .project(project.id)
            case let .repo(repo): .repo(project.id, repo)
            case let .attempt(attempt): .attempt(project.id, attempt.id)
            }
        }
    }

    /// The tree, flattened in display order: each Project, then each of its Repos followed by the
    /// Attempt running in it, if any.
    private var treeRows: [TreeRow] {
        snapshot.projects.flatMap { project in
            [TreeRow(project: project, kind: .project)] + project.repos.flatMap { repo in
                [TreeRow(project: project, kind: .repo(repo))]
                    + (project.runningAttempt(for: repo).map { [TreeRow(project: project, kind: .attempt($0))] } ?? [])
            }
        }
    }

    /// The row selection, kept in step with the Project selection the harness owns.
    private var tagSelection: Binding<PulseSidebarTag?> {
        let rowSelection = $rowSelection
        let selection = $selection
        let actions = actions
        return Binding {
            if let row = rowSelection.wrappedValue, row.projectID == selection.wrappedValue { return row }
            return selection.wrappedValue.map(PulseSidebarTag.project)
        } set: { tag in
            rowSelection.wrappedValue = tag
            guard let tag else { return }
            selection.wrappedValue = tag.projectID
            switch tag {
            case .project: break
            case let .repo(_, repo): actions.inspect(.repo(repo))
            case let .attempt(_, attempt): actions.inspect(.attempt(attempt))
            }
        }
    }

    // MARK: Project

    @ViewBuilder
    private func projectRow(_ project: ProjectSnapshot) -> some View {
        switch rows {
        case .sourceList:
            Label {
                HStack {
                    Text(project.name).lineLimit(1)
                    Spacer()
                    Text(project.status.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: project.status == .working ? "circle.fill" : "circle")
                    .foregroundStyle(palette.color(for: project.status))
            }
        case .badged:
            Label {
                Text(project.name).lineLimit(1)
            } icon: {
                Image(systemName: "folder.fill")
                    .foregroundStyle(palette.accent)
                    .overlay(alignment: .bottomTrailing) {
                        PulseStatusDot(color: palette.color(for: project.status), size: 7)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
            }
            .badge(project.pulse.needsYou.cards.count)
        case .twoLine:
            HStack(spacing: 8) {
                PulseStatusDot(color: palette.color(for: project.status))
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).fontWeight(.semibold).lineLimit(1)
                    Text(twoLineSubtitle(project)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func twoLineSubtitle(_ project: ProjectSnapshot) -> String {
        let needsYou = project.pulse.needsYou.cards.count
        let now = PulseFormat.nowLine(project.pulse.now)
        return needsYou > 0 ? "\(needsYou) need you · \(now)" : now
    }

    // MARK: Repo

    @ViewBuilder
    private func repoRow(_ repo: String, in project: ProjectSnapshot) -> some View {
        let lane = project.laneState(for: repo)
        switch rows {
        case .sourceList:
            HStack {
                Label(repo, systemImage: "shippingbox").lineLimit(1).truncationMode(.middle)
                Spacer()
                if let lane {
                    Text(lane.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: .capsule)
                }
            }
        case .badged:
            HStack {
                Label(repo, systemImage: "shippingbox").lineLimit(1).truncationMode(.middle)
                Spacer()
                if let lane {
                    PulseStatusDot(color: palette.color(for: lane), size: 7).help(lane.rawValue)
                }
            }
        case .twoLine:
            HStack {
                Label(repo, systemImage: "shippingbox").font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let lane { PulseBadge(text: lane.rawValue, color: palette.color(for: lane)) }
            }
        }
    }

    // MARK: Attempt

    private func attemptRow(_ attempt: RunningAttempt) -> some View {
        HStack {
            Label {
                Text(rows == .twoLine ? "\(attempt.cardID) · Round \(attempt.round)" : attempt.route).lineLimit(1)
            } icon: {
                Image(systemName: "gearshape.2").foregroundStyle(palette.working)
            }
            Spacer()
            Text(PulseFormat.elapsed(since: attempt.startedAt, asOf: snapshot.asOf))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private enum TreeRowKind {
    case project
    case repo(String)
    case attempt(RunningAttempt)
}
#endif
