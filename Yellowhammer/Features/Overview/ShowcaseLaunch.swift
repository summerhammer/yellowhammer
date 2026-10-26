import AppKit
import Domain
import Foundation
import Pulse
import SwiftUI

/// How a DEBUG build opens its main window for one landing-page screenshot, from launch arguments that
/// `Tools/LandingScreenshots` passes. Never in Release, and only from the argument domain, so nothing can
/// persist through `defaults write`.
///
/// - `-YellowhammerShowcaseProject <id>` scopes the window to that Project. It switches the others on.
/// - `-YellowhammerShowcaseInspect night|attempt:<id>` opens the Inspector on the Project's Night (whose
///   account then takes the main area) or on one of its Attempts.
/// - `-YellowhammerShowcaseHide sidebar,inspector` hides those columns; any not named is shown, whatever
///   the window last saved.
/// - `-YellowhammerShowcaseReady <path>` names a file the window writes once it shows the asked state: the
///   Pulse's status title and line, one per line, so the tool can check the state before it captures.
struct ShowcaseLaunch {
    enum Inspect: Equatable {
        case night
        case attempt(String)
    }

    let project: ProjectID
    let inspect: Inspect?
    let hidesSidebar: Bool
    let hidesInspector: Bool
    let readyFile: URL?

    static let current: ShowcaseLaunch? = {
#if DEBUG
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return parse(
            project: arguments["YellowhammerShowcaseProject"] as? String,
            inspect: arguments["YellowhammerShowcaseInspect"] as? String,
            hide: arguments["YellowhammerShowcaseHide"] as? String,
            ready: arguments["YellowhammerShowcaseReady"] as? String
        )
#else
        return nil
#endif
    }()

    static func parse(project: String?, inspect: String?, hide: String?, ready: String?) -> ShowcaseLaunch? {
        guard let project = project.flatMap(ProjectID.init(rawValue:)) else { return nil }
        let inspected: Inspect? = switch inspect {
        case "night": .night
        case let value? where value.hasPrefix("attempt:"): .attempt(String(value.dropFirst("attempt:".count)))
        default: nil
        }
        let hidden = Set((hide ?? "").split(separator: ",").map(String.init))
        return ShowcaseLaunch(
            project: project, inspect: inspected, hidesSidebar: hidden.contains("sidebar"),
            hidesInspector: hidden.contains("inspector"), readyFile: ready.map { URL(filePath: $0) }
        )
    }

    /// The sidebar's visibility for the main window: as asked under a showcase launch, else the default.
    static var columnVisibility: NavigationSplitViewVisibility {
        guard let current else { return .automatic }
        return current.hidesSidebar ? .detailOnly : .all
    }

    /// Writes the ready file: `title`, then `line`.
    func markReady(title: String, line: String) {
        guard let readyFile else { return }
        try? Data("\(title)\n\(line)\n".utf8).write(to: readyFile, options: .atomic)
    }
}

extension View {
    /// Under a DEBUG screenshot launch (`ShowcaseLaunch`), once the first snapshot is read: scopes the window to
    /// the asked Project, opens what it asked for, and writes the ready file once the account or Inspector has
    /// had a moment to read. Does nothing otherwise.
    @ViewBuilder
    func showcaseLaunch(
        _ snapshot: LandingSnapshot?, scope: @escaping (ProjectID) -> Void, inspectorShown: Binding<Bool>,
        inspected: Binding<PulseSelection?>
    ) -> some View {
        if ShowcaseLaunch.current == nil {
            self
        } else {
            modifier(ShowcaseLaunchModifier(
                snapshot: snapshot, scope: scope, inspectorShown: inspectorShown, inspected: inspected
            ))
        }
    }
}

private struct ShowcaseLaunchModifier: ViewModifier {
    let snapshot: LandingSnapshot?
    let scope: (ProjectID) -> Void
    @Binding var inspectorShown: Bool
    @Binding var inspected: PulseSelection?
    @State private var applied = false

    func body(content: Content) -> some View {
        content
            // Brought to the front by the tool, the window would show a focus ring on its first control.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let window = note.object as? NSWindow else { return }
                DispatchQueue.main.async { window.makeFirstResponder(nil) }
            }
            .task(id: snapshot != nil) {
                guard !applied, let launch = ShowcaseLaunch.current, let selected = snapshot?.project(launch.project)
                else { return }
                applied = true
                scope(launch.project)
                inspectorShown = !launch.hidesInspector
                switch launch.inspect {
                case .night: inspected = selected.pulse.night.map { .night($0.id) }
                case let .attempt(id): inspected = .attempt(id)
                case nil: break
                }
                try? await Task.sleep(for: .seconds(1))
                let condition = PulseCondition(project: selected)
                launch.markReady(title: condition.title, line: condition.line)
            }
    }
}
