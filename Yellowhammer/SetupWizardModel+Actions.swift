import AppKit
import Domain
import Foundation
import UserNotifications

/// The Setup wizard model's side effects: folder pickers, and the two `yh` runs
/// (`--print-choices` and `--init`). Split from ``SetupWizardModel`` to keep the state declaration
/// readable; nothing here is public API outside the app module.
extension SetupWizardModel {
    func chooseSpecSource() {
        guard let url = Self.chooseFolder() else { return }
        specSource = Self.abbreviatingPath(url)
    }

    func chooseRepoPath(for id: RepoField.ID) {
        guard let url = Self.chooseFolder(), let index = repos.firstIndex(where: { $0.id == id }) else { return }
        repos[index].path = Self.abbreviatingPath(url)
    }

    func chooseExportDirectory() {
        // Full path, not `~`-abbreviated: `yh` takes `--export-jobs` as a literal directory path.
        guard let url = Self.chooseFolder() else { return }
        exportDirectory = url.path(percentEncoded: false)
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
            let status = try await engine.run(
                arguments: arguments, standardInput: linearSecret.isEmpty ? nil : linearSecret + "\n"
            ) { lines.append($0) }
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
        defer { isRunning = false }
        let invocation = buildInvocation()
        do {
            let arguments = try invocation.arguments()
            let status = try await engine.run(
                arguments: arguments, standardInput: linearSecret.isEmpty ? nil : linearSecret + "\n"
            ) { [weak self] line in self?.runLines.append(line) }
            runExitStatus = status
            guard status == 0 else { return }
            if let project = invocation.project, let id = ProjectID(rawValue: project.id) {
                declaredProjectID = id
                declaredProjectName = project.name ?? project.id
            }
            configExists = true
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
        SetupInvocation(
            linearCredential: configExists || linearCredential == Self.defaultLinearCredential ? nil : linearCredential,
            githubCredential: configExists || githubCredential == Self.defaultGitHubCredential ? nil : githubCredential,
            cliAdapters: configExists ? [] : enabledCLIs.sorted().map { name in
                if let executable = cliExecutables[name], !executable.trimmed.isEmpty {
                    return "\(name)=\(executable)"
                }
                return name
            },
            route: configExists ? nil : routeText,
            fallbacks: configExists ? [] : fallbackTexts,
            operatorID: selectedOperatorID,
            project: declareProject ? SetupInvocation.Project(
                id: projectID.trimmed,
                name: projectName,
                linearProject: linearProjectMode == .existing
                    ? .existing(existingLinearProjectID.trimmed)
                    : .createInTeam(key: selectedTeamKey ?? ""),
                specSource: specSource,
                repos: repos.map {
                    SetupInvocation.Repo(
                        name: $0.name.trimmed, role: $0.role.trimmed, path: $0.path.trimmed,
                        check: $0.check.trimmed
                    )
                }
            ) : nil,
            jobs: jobsInvocationValue()
        )
    }

    private func jobsInvocationValue() -> SetupInvocation.Jobs {
        switch jobsSelection {
        case .install: .install
        case .notNow: .notNow
        case .export: .export(directory: exportDirectory, cron: exportUsesCron)
        }
    }
}
