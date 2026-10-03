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

    /// Runs when the sheet appears: checks the Linear installation, then, if it is there, reads what it
    /// unlocks. The check runs here rather than in the readiness panel, so a ready Mac never flashes it.
    func checkReadiness() async {
        await linearInstallation.checkExistingLinearInstallation()
        await linearInstallationChanged()
    }

    /// The Linear installation was found or just installed: `--install-linear` may have written the machine
    /// file on a Mac that had none, and the teams can now be read.
    func linearInstallationChanged() async {
        loadContext()
        guard linearInstallation.phase.isInstalled, draft.context.teams.isEmpty else { return }
        await fetchTeams()
    }

    /// Reads the teams a Linear project can be created in. `yh` always reads the real configuration, so while
    /// the app is pointed at another one (a UI test's fixture) it is not run unless a stub stands in for it.
    func fetchTeams() async {
        guard !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed, !isFetchingTeams else { return }
        isFetchingTeams = true
        teamsFailure = []
        defer { isFetchingTeams = false }
        let arguments = SetupInvocation.choicesArguments(
            // One installation until the wizard offers a choice (roadmap L3.1).
            installation: draft.context.linearInstallationName, githubCredential: nil
        )
        var lines: [String] = []
        do {
            let status = try await engine.run(arguments: arguments, standardInput: nil) { lines.append($0) }
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
            loadContext()
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
