import AppKit
import Config
import Domain
import Foundation
import Observation
import Pulse

/// View-state and operations for the read-only recorded dispatch prompt viewer.
/// Loads the index on open and when asOf changes, and executes prompt deletion through `SetupEngine`.
@MainActor
@Observable
final class PromptViewerModel {
    enum TargetScope: Equatable, Sendable {
        case attempt(cardID: Int64, attemptID: Int64)
        case attemptByIssue(issueID: String, attemptID: Int64)
        case night(nightID: Int64)
    }

    let projectID: ProjectID
    let targetScope: TargetScope
    let configurationDirectory: URL

    private(set) var index: DispatchPromptIndex?
    private(set) var readFailure: String?
    private(set) var isLoading = false
    var selectedItemID: String?

    var confirmingCopy = false
    var confirmingDelete = false
    private(set) var isDeleting = false
    var deleteFailure: String?

    private let engine: SetupEngine

    init(
        projectID: ProjectID,
        issueID: String,
        attemptID: Int64,
        configurationDirectory: URL = ConfigurationDirectory.current,
        engine: SetupEngine = SetupEngine()
    ) {
        self.projectID = projectID
        self.targetScope = .attemptByIssue(issueID: issueID, attemptID: attemptID)
        self.configurationDirectory = configurationDirectory
        self.engine = engine
    }

    init(
        projectID: ProjectID,
        scope: DispatchPromptIndex.Scope,
        configurationDirectory: URL = ConfigurationDirectory.current,
        engine: SetupEngine = SetupEngine()
    ) {
        self.projectID = projectID
        switch scope {
        case let .attempt(cardID, attemptID):
            self.targetScope = .attempt(cardID: cardID, attemptID: attemptID)
        case let .night(nightID):
            self.targetScope = .night(nightID: nightID)
        }
        self.configurationDirectory = configurationDirectory
        self.engine = engine
    }

    var selectedItem: DispatchPromptItem? {
        guard let selectedItemID else { return index?.items.first }
        return index?.items.first { $0.id == selectedItemID } ?? index?.items.first
    }

    func load(asOf: Date = Date()) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        readFailure = nil

        let directory = configurationDirectory
        let project = projectID
        let scope = targetScope

        let readResult = await Self.readIndex(
            directory: directory, project: project, scope: scope, asOf: asOf
        )
        guard !Task.isCancelled else { return }

        switch readResult {
        case let .index(loaded):
            index = loaded
            if selectedItemID == nil || !loaded.items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = loaded.items.first?.id
            }
        case .noSuchCard:
            index = nil
            readFailure = "The Journal does not record this Card."
        case .noSuchAttempt:
            index = nil
            readFailure = "The Journal does not record this Attempt."
        case .noSuchNight:
            index = nil
            readFailure = "The Journal does not record this Night."
        case .journalMissing:
            index = nil
            readFailure = "This Project has no Journal."
        case let .journalFailure(error):
            index = nil
            readFailure = "Yellowhammer can\u{2019}t read this Project\u{2019}s Journal: \(error)"
        }
    }

    @concurrent
    private nonisolated static func readIndex(
        directory: URL, project: ProjectID, scope: TargetScope, asOf: Date
    ) async -> DispatchPromptIndexRead {
        switch scope {
        case let .attempt(cardID, attemptID):
            return DispatchPromptIndex.read(
                configurationDirectory: directory,
                projectID: project,
                scope: .attempt(cardID: cardID, attemptID: attemptID),
                asOf: asOf
            )
        case let .attemptByIssue(issueID, attemptID):
            return DispatchPromptIndex.read(
                configurationDirectory: directory,
                projectID: project,
                issueID: issueID,
                attemptID: attemptID,
                asOf: asOf
            )
        case let .night(nightID):
            return DispatchPromptIndex.read(
                configurationDirectory: directory,
                projectID: project,
                scope: .night(nightID: nightID),
                asOf: asOf
            )
        }
    }

    @discardableResult
    func copySelectedPrompt() -> Bool {
        guard let item = selectedItem else { return false }
        let text: String
        if let instruction = item.instruction, let schema = item.outputSchema {
            text = "\(instruction)\n\n\(schema)"
        } else {
            text = item.instruction ?? item.outputSchema ?? ""
        }
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    func deleteSelected() async {
        guard let recordID = selectedItem?.recordID else { return }
        guard !isDeleting else { return }
        isDeleting = true
        deleteFailure = nil
        defer { isDeleting = false }

        var outputLines: [String] = []
        do {
            let status = try await engine.run(
                arguments: ["prompts", "delete", "--project", projectID.rawValue, recordID]
            ) { line in
                outputLines.append(line)
            }

            var failures: [String] = []
            for line in outputLines where line.hasPrefix("failed ") {
                failures.append(line)
            }
            if status != 0 || !failures.isEmpty {
                deleteFailure = failures.isEmpty
                    ? outputLines.suffix(3).joined(separator: "\n")
                    : failures.joined(separator: "\n")
                if deleteFailure?.isEmpty ?? true {
                    deleteFailure = "Deletion failed with exit status \(status)."
                }
            }
        } catch {
            deleteFailure = "\(error)"
        }

        await load()
    }
}
