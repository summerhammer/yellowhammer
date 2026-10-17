import AppKit
import Domain
import SwiftUI

/// The last pointer in a failed item's details: its Act's log, as a `~` path the Operator can select, with
/// Reveal in Finder (morning-report/disclose-a-failure#log-path). Offered only on a failed item, never on a
/// running or successful one, and it shows no excerpt: the app reads nothing from the file.
///
/// The URL is the app's one way to name an Act's log (`SetupEngine.logURL(projectID:act:)`), so the UI-test
/// stub seam holds. When the file does not exist yet, Reveal opens the nearest folder that does.
struct ActLogPointer: View {
    let act: Act
    @Environment(\.actLogProject) private var project

    var body: some View {
        if let url = logURL {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(act.rawValue.capitalized) Act log: \(Self.abbreviated(url))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("act-log-path")
                Button("Reveal in Finder") { Self.reveal(url) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("act-log-reveal")
            }
        }
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private var logURL: URL? {
        project.map { SetupEngine.logURL(projectID: $0.rawValue, act: act) }
    }

    /// Selects the log in Finder, or — before the Act has written one — the nearest folder that exists.
    private static func reveal(_ url: URL) {
        var target = url
        let exists = { FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) }
        while !exists(), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

extension EnvironmentValues {
    /// The Project whose failed items a view shows, so a failed item can name its Act's log. Nil where no
    /// window installs it, which offers no pointer.
    @Entry var actLogProject: ProjectID?
}
