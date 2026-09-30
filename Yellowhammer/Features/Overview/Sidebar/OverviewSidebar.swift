import Domain
import Pulse
import SwiftUI

/// The main window's Sidebar: every configured Project as a tree. A Project's rows are the Project,
/// then each of its configured Repos in `[repos]` declared order, then, nested under a Repo, the Attempt
/// running in it while one runs. Projects are in configured order, and nothing is re-sorted.
///
/// A Project row shows the Project's name and its derived `idle`/`working` status, and nothing else: no
/// count, badge, roll-up word or health indicator (R20). When the Project's Journal could not be read,
/// the row shows no status, because none can be derived; the Pulse states why. A Repo row shows a lane
/// badge only while that Repo is in lane, so the badge, not the row's position, marks an active Repo.
///
/// Each row's values come from its own Project's snapshot alone. A Project whose configuration was
/// refused is not in `projects`, so it never appears here (OQ79).
///
/// Selecting a Project row scopes the Pulse to that Project. Selecting a Repo or Attempt row scopes the
/// Pulse to its Project and opens the row in the Inspector.
struct OverviewSidebar: View {
    let projects: [ProjectSnapshot]
    /// The Project the window shows. The Sidebar sets it; the window owns it.
    @Binding var selection: ProjectID?
    /// The highlighted row. Only its Project belongs to the window; which of that Project's rows is
    /// highlighted is the Sidebar's own concern.
    @State private var highlighted: SidebarRowID?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        // One flat ForEach with exactly one view per element: a macOS sidebar List traps when one
        // ForEach element yields a varying number of rows, as an optional Attempt row would.
        List(selection: rowSelection) {
            Section("Projects") {
                ForEach(rows) { row in
                    switch row.kind {
                    case .project:
                        ProjectRow(
                            id: row.snapshot.id,
                            name: row.snapshot.name,
                            status: row.snapshot.journalFailure == nil ? row.snapshot.status : nil
                        )
                    case let .repo(repo):
                        RepoRow(projectID: row.snapshot.id, repo: repo, lane: row.snapshot.laneState(for: repo))
                            .padding(.leading, 16)
                    case let .attempt(attempt):
                        // The running Attempt: its Card and route. No output of the agent CLI, ever.
                        Label("\(attempt.cardID) \u{00B7} \(attempt.route)", systemImage: "gearshape.2")
                            .font(.caption)
                            .lineLimit(1)
                            .accessibilityIdentifier("sidebar-\(row.snapshot.id.rawValue)-attempt-\(attempt.id)")
                            .padding(.leading, 32)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Tree

    /// The tree in display order: each Project, then each of its Repos, each followed by the Attempt
    /// running in it, if any.
    private var rows: [SidebarRow] {
        projects.flatMap { snapshot in
            [SidebarRow(snapshot: snapshot, kind: .project)] + snapshot.repos.flatMap { repo in
                let repoRow = SidebarRow(snapshot: snapshot, kind: .repo(repo))
                guard let attempt = snapshot.runningAttempt(for: repo) else { return [repoRow] }
                return [repoRow, SidebarRow(snapshot: snapshot, kind: .attempt(attempt))]
            }
        }
    }

    /// The highlighted row, kept in step with the window's Project. Setting a row scopes the window to
    /// its Project first, then opens a Repo or Attempt row in the Inspector, so the window's change of
    /// Project cannot clear what this row opens.
    private var rowSelection: Binding<SidebarRowID?> {
        let highlighted = $highlighted
        let selection = $selection
        let openDestination = openDestination
        return Binding {
            if let row = highlighted.wrappedValue, row.projectID == selection.wrappedValue { return row }
            return selection.wrappedValue.map(SidebarRowID.project)
        } set: { row in
            guard let row else { return }
            highlighted.wrappedValue = row
            selection.wrappedValue = row.projectID
            switch row {
            case .project: break
            case let .repo(_, repo): openDestination(.inspector(.repo(repo)))
            case let .attempt(_, attempt): openDestination(.inspector(.attempt(attempt)))
            }
        }
    }
}

/// A Project row: the Project's name and its derived `idle`/`working` status, and nothing else. `status`
/// is nil when the Project's Journal could not be read, because none can be derived.
private struct ProjectRow: View {
    let id: ProjectID
    let name: String
    let status: ProjectStatus?

    var body: some View {
        HStack {
            Text(name)
                .lineLimit(1)
                .accessibilityIdentifier("sidebar-\(id.rawValue)")
            Spacer()
            if let status {
                Text(status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sidebar-\(id.rawValue)-status")
            }
        }
    }
}

/// A Repo row, with a lane badge only while the Repo is in lane.
private struct RepoRow: View {
    let projectID: ProjectID
    let repo: String
    let lane: LaneState?

    var body: some View {
        HStack {
            Label(repo, systemImage: "shippingbox")
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("sidebar-\(projectID.rawValue)-repo-\(repo)")
            Spacer()
            if let lane {
                Text(lane.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: .capsule)
                    .accessibilityIdentifier("sidebar-\(projectID.rawValue)-repo-\(repo)-lane")
            }
        }
    }
}

/// A Sidebar row's identity, and the tag the List selects. It names the row's Project, so selecting any
/// row can scope the window to that Project.
private enum SidebarRowID: Hashable {
    case project(ProjectID)
    case repo(ProjectID, String)
    case attempt(ProjectID, String)

    var projectID: ProjectID {
        switch self {
        case let .project(id), let .repo(id, _), let .attempt(id, _): id
        }
    }
}

/// One Sidebar row: the Project it belongs to, and what it shows.
private struct SidebarRow: Identifiable {
    enum Kind {
        case project
        case repo(String)
        case attempt(RunningAttempt)
    }

    let snapshot: ProjectSnapshot
    let kind: Kind

    var id: SidebarRowID {
        switch kind {
        case .project: .project(snapshot.id)
        case let .repo(repo): .repo(snapshot.id, repo)
        case let .attempt(attempt): .attempt(snapshot.id, attempt.id)
        }
    }
}
