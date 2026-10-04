import AppKit
import Config
import Domain
import Foundation
import UserNotifications

/// The Add Project model's side effects: the folder picker, and the two `yh` runs (`--print-choices` and
/// `--init`). Split from ``SetupWizardModel`` to keep the state declaration readable; nothing here is public
/// API outside the app module.
extension SetupWizardModel {
    /// The launch argument that stands in for the folder picker in UI tests
    /// (`-YellowhammerFolderPickerStub <path>`): every pick returns that path, since an `NSOpenPanel` is not
    /// reliably driven from XCUITest. Only the argument domain is read, so it cannot persist through
    /// `defaults write`.
    static let folderPickerStubArgument = "YellowhammerFolderPickerStub"

    static func chooseFolder() -> URL? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let stubPath = arguments[folderPickerStubArgument] as? String {
            return URL(filePath: stubPath, directoryHint: .isDirectory)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func abbreviatingPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// Runs when the sheet appears: reads the Linear workspaces' names once, then, if an installation is
    /// already selected, reads what it unlocks.
    func appeared() async {
        linearWorkspaces.refreshStatusOnFirstAppearance()
        guard draft.linearInstallationName != nil else { return }
        await fetchTeams()
    }

    /// Selects the Linear workspace by its local name. A different one clears the previous workspace's
    /// choices and reads its own teams and Linear projects; the same one changes nothing.
    func selectLinearInstallation(_ name: String) async {
        guard draft.linearInstallationName != name else { return }
        draft.selectLinearInstallation(name)
        await fetchTeams()
    }

    /// Reads the teams and Linear projects of the selected installation. `yh` always reads the real
    /// configuration, so while the app is pointed at another one (a UI test's fixture) it is not run unless a
    /// stub stands in for it. A response for an installation that is no longer selected is dropped.
    func fetchTeams() async {
        guard !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed,
              let installation = draft.linearInstallationName else { return }
        teamsEngine.terminate()
        let fetchEngine = SetupEngine()
        teamsEngine = fetchEngine
        teamsFetchGeneration += 1
        let generation = teamsFetchGeneration
        isFetchingTeams = true
        teamsFailure = []
        defer { if generation == teamsFetchGeneration { isFetchingTeams = false } }
        let arguments = SetupInvocation.choicesArguments(installation: installation, githubCredential: nil)
        var lines: [String] = []
        do {
            let status = try await fetchEngine.run(arguments: arguments, standardInput: nil) { lines.append($0) }
            guard generation == teamsFetchGeneration, draft.linearInstallationName == installation else { return }
            guard status == 0 else {
                teamsFailure = lines.isEmpty ? ["yh exited \(status)."] : lines
                return
            }
            guard let lastLine = lines.last(where: { !$0.isEmpty }),
                  let data = lastLine.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SetupChoices.self, from: data)
            else {
                teamsFailure = lines + ["Yellowhammer could not read yh's response."]
                return
            }
            draft.context.teams = decoded.teams
            draft.context.linearProjects = decoded.linearProjects
        } catch {
            guard generation == teamsFetchGeneration, draft.linearInstallationName == installation else { return }
            teamsFailure = ["\(error)"]
        }
    }

    func runSetup() async {
        isRunning = true
        runLines = []
        runExitStatus = nil
        boundsFailure = nil
        defer { isRunning = false }
        // Nothing machine-wide: `yh setup --init` keeps the configured Operator identity, CLIs and routes.
        let invocation = draft.setupInvocation
        do {
            let arguments = try invocation.arguments()
            let status = try await engine.run(
                arguments: arguments, standardInput: nil
            ) { [weak self] line in self?.runLines.append(line) }
            guard status == 0 else {
                runExitStatus = status
                return
            }
            if let project = invocation.project, let id = ProjectID(rawValue: project.id) {
                declaredProjectID = id
                declaredProjectName = project.name ?? project.id
            }
            if let id = declaredProjectID, let bounds = draft.boundsToWrite(afterExitStatus: status) {
                writeBounds(bounds, for: id)
            }
            await checkNotificationStatus()
            // Last, so Done appears only once everything the run does after `yh` is finished.
            runExitStatus = status
        } catch let error as SetupInvocationError {
            runLines.append(error.description)
            runExitStatus = -1
        } catch {
            runLines.append("\(error)")
            runExitStatus = -1
        }
    }

    /// Writes the Bounds through the Settings path after a successful setup. A refusal leaves the Project in
    /// place with default Bounds and is reported in ``boundsFailure``; nothing is rolled back.
    func writeBounds(_ bounds: Bounds, for id: ProjectID) {
        let configuration = ProjectConfigurationModel(project: id, directory: configurationDirectory)
        configuration.draft?.bounds = BoundsDraft(bounds)
        if !configuration.save() {
            boundsFailure = configuration.failure ?? configuration.loadFailure
                ?? "The Bounds could not be written."
        }
    }

    func checkNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            if settings.timeSensitiveSetting == .enabled {
                notificationStatusLine = "Local notifications are on."
            } else {
                notificationStatusLine = "Local notifications are on, but Time Sensitive " // glossary:ignore GL001
                    + "delivery is off, so they arrive quieter."
            }
        default:
            notificationStatusLine = "Local notifications are off. Halted and closed " // glossary:ignore GL001
                + "Nights still reach you on the Night Card in Linear."
        }
    }
}
