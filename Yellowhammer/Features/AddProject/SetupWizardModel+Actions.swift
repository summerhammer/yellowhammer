import AppKit
import Config
import Domain
import Foundation
import UserNotifications

/// The Setup wizard model's side effects: folder pickers, and the two `yh` runs
/// (`--print-choices` and `--init`). Split from ``SetupWizardModel`` to keep the state declaration
/// readable; nothing here is public API outside the app module.
extension SetupWizardModel {
    func chooseSpecSource() {
        guard let url = Self.chooseFolder() else { return }
        draft.specSourcePath = Self.abbreviatingPath(url)
    }

    func chooseRepoPath(for id: AddProjectDraft.Repo.ID) {
        guard let url = Self.chooseFolder(), let index = draft.repos.firstIndex(where: { $0.id == id }) else { return }
        draft.repos[index].path = Self.abbreviatingPath(url)
    }

    func chooseExportDirectory() {
        // Full path, not `~`-abbreviated: `yh` takes `--export-jobs` as a literal directory path.
        guard let url = Self.chooseFolder() else { return }
        draft.exportDirectory = url.path(percentEncoded: false)
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func abbreviatingPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    func fetchChoices() async {
        isFetchingChoices = true
        choicesErrorOutput = []
        defer { isFetchingChoices = false }
        let arguments = SetupInvocation.choicesArguments(
            linearCredential: configExists || linearCredential == Self.defaultLinearCredential ? nil : linearCredential,
            githubCredential: configExists || githubCredential == Self.defaultGitHubCredential ? nil : githubCredential
        )
        var lines: [String] = []
        do {
            let status = try await engine.run(arguments: arguments, standardInput: nil) { lines.append($0) }
            guard status == 0 else {
                choicesErrorOutput = lines.isEmpty ? ["yh exited \(status)."] : lines
                return
            }
            guard let lastLine = lines.last(where: { !$0.isEmpty }),
                  let data = lastLine.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SetupChoices.self, from: data)
            else {
                choicesErrorOutput = lines + ["Yellowhammer could not read yh's response."]
                return
            }
            choices = decoded
            draft.context.teams = decoded.teams
            selectedOperatorID = decoded.configuredOperator
            advance()
        } catch {
            choicesErrorOutput = ["\(error)"]
        }
    }

    func runSetup() async {
        isRunning = true
        runLines = []
        runExitStatus = nil
        boundsFailure = nil
        defer { isRunning = false }
        let invocation = buildInvocation()
        do {
            let arguments = try invocation.arguments()
            let status = try await engine.run(
                arguments: arguments, standardInput: nil
            ) { [weak self] line in self?.runLines.append(line) }
            runExitStatus = status
            guard status == 0 else { return }
            if let project = invocation.project, let id = ProjectID(rawValue: project.id) {
                declaredProjectID = id
                declaredProjectName = project.name ?? project.id
            }
            if let id = declaredProjectID, let bounds = draft.boundsToWrite(afterExitStatus: status) {
                writeBounds(bounds, for: id)
            }
            configExists = true
            loadContext()
            // `activeSteps` just dropped `.cliRouting` now that `configExists` flipped, so re-anchor on
            // `.review` rather than leaving `currentStepIndex` pointing past the end of the new array.
            currentStepIndex = activeSteps.firstIndex(of: .review) ?? currentStepIndex
            await checkNotificationStatus()
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

    func buildInvocation() -> SetupInvocation {
        var invocation = draft.setupInvocation
        invocation.linearCredential = configExists || linearCredential == Self.defaultLinearCredential
            ? nil : linearCredential
        invocation.githubCredential = configExists || githubCredential == Self.defaultGitHubCredential
            ? nil : githubCredential
        invocation.cliAdapters = configExists ? [] : enabledCLIs.sorted().map { name in
            if let executable = cliExecutables[name], !executable.trimmed.isEmpty {
                return "\(name)=\(executable)"
            }
            return name
        }
        invocation.route = configExists ? nil : routeText
        invocation.fallbacks = configExists ? [] : fallbackTexts
        invocation.operatorID = selectedOperatorID
        return invocation
    }
}
