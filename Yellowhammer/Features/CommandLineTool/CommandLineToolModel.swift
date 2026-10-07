import AppKit
import Config
import Foundation

/// State and actions for installing, updating, and uninstalling the Command Line Tool (`yh`) symlink.
///
/// Follows the non-resident invariant: one-shot filesystem actions, zero persisted configuration state.
/// State is determined only by inspecting `/usr/local/bin/yh` live (or the `-YellowhammerCommandLineToolLink` override).
@MainActor
@Observable
final class CommandLineToolModel {
    enum ConfirmationAction: Identifiable, Sendable {
        case install
        case update
        case uninstall
        case moveDetected(target: String)

        var id: String {
            switch self {
            case .install: "install"
            case .update: "update"
            case .uninstall: "uninstall"
            case .moveDetected: "moveDetected"
            }
        }
    }

    private let link: CommandLineToolLink
    let linkPath: String
    private(set) var state: CommandLineToolLinkState = .notInstalled
    let runningExecutablePath: String
    var pendingConfirmation: ConfirmationAction?
    var lastError: String?

    init(
        linkPath: String? = nil,
        runningExecutablePath: String? = nil
    ) {
        let resolvedLinkPath = linkPath
            ?? CommandLineToolLink.overrideLinkPath
            ?? CommandLineToolLink.defaultPath
        self.linkPath = resolvedLinkPath
        self.link = CommandLineToolLink(path: resolvedLinkPath)
        let resolvedExecutable = runningExecutablePath
            ?? Bundle.main.url(forAuxiliaryExecutable: "yh")?.resolvingSymlinksInPath().path
            ?? CommandLineToolLink.runningExecutablePath()
        self.runningExecutablePath = resolvedExecutable
        refresh()
    }

    func refresh() {
        state = link.inspect(runningExecutable: runningExecutablePath)
    }

    var isSymlink: Bool {
        link.isSymlink
    }

    var isParentDirectoryWritable: Bool {
        link.isParentDirectoryWritable
    }

    private var hasCheckedOnLaunch = false

    /// Move detection on open (ruling item 6):
    /// Check once per app launch (not once per window).
    /// If the link is a dangling or mismatched symlink, show a dedicated alert that offers Update
    /// (with the same confirmation and execution) or Not Now. Rewrite nothing until the Operator confirms.
    /// Never alert when the link is absent or installed. Never persist a "don't ask again".
    /// Skip the check under a UI test (SetupEngine.isStubbed) unless the link override is given.
    func checkOnLaunch() {
        guard !hasCheckedOnLaunch else { return }
        hasCheckedOnLaunch = true
        if SetupEngine.isStubbed && !CommandLineToolLink.isOverridden {
            return
        }
        refresh()
        switch state {
        case .mismatched(let target), .dangling(let target):
            guard link.isSymlink else { return }
            if pendingConfirmation == nil {
                pendingConfirmation = .moveDetected(target: target)
            }
        case .notInstalled, .installed:
            break
        }
    }

    func dismissMoveDetection(for target: String) {
        pendingConfirmation = nil
    }

    func promptInstall() {
        pendingConfirmation = .install
    }

    func promptUpdate() {
        pendingConfirmation = .update
    }

    func promptUninstall() {
        pendingConfirmation = .uninstall
    }

    func performInstall() {
        if link.isParentDirectoryWritable {
            do {
                try link.install(target: runningExecutablePath)
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            let privilegedCommand = link.privilegedInstallCommand(target: runningExecutablePath)
            do {
                try runPrivileged(privilegedCommand)
            } catch {
                lastError = error.localizedDescription
            }
        }
        refresh()
    }

    func performUninstall() {
        if link.isParentDirectoryWritable {
            do {
                try link.uninstall()
            } catch {
                lastError = error.localizedDescription
            }
        } else {
            do {
                try link.checkUninstallEligibility()
                let privilegedCommand = link.privilegedUninstallCommand()
                try runPrivileged(privilegedCommand)
            } catch {
                lastError = error.localizedDescription
            }
        }
        refresh()
    }

    private func runPrivileged(_ shellCommand: String) throws {
        let escaped = CommandLineToolLink.appleScriptEscape(shellCommand)
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            // The Operator cancelling (AppleScript error -128) changes nothing and shows no error.
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                return
            }
            throw CommandLineToolExecutionError(message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

struct CommandLineToolExecutionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
