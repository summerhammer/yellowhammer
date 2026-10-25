import Config
import Domain
import Foundation

/// Read-only index of captured dispatch prompts for an Attempt or a Night.
public struct DispatchPromptIndex: Equatable, Sendable {
    /// The target scope of prompt evidence: one Attempt's dispatches or a whole Night's dispatches.
    public enum Scope: Hashable, Sendable {
        case attempt(cardID: Int64, attemptID: Int64)
        case night(nightID: Int64)
    }

    /// Distinct empty state when no prompt records are viewable.
    public enum EmptyState: Equatable, Sendable {
        /// No dispatch has occurred yet for this scope.
        case noDispatchesYet
        /// The pass or Act was skipped before any dispatch.
        case skipped(reason: String)
        /// Legacy dispatches exist without prompt capture evidence (historical before prompt capture was added).
        case legacy
    }

    /// The state of an individual dispatch's prompt record.
    public enum EntryState: Equatable, Sendable {
        /// Fully captured and available on disk.
        case recorded(DispatchPromptRecord)
        /// Expired after 30 days from dispatch.
        case expired(dispatchedAt: Date)
        /// Deleted; a tombstone was found.
        case deleted(deletedAt: Date)
        /// Within 30 days but missing from disk, or unreadable due to permissions/corruption.
        case unavailable(cause: String?)
        /// A rehearsal pass answered from a fixture; no agent CLI process was dispatched.
        case rehearsal(fixture: String)
    }

    public let projectID: ProjectID
    public let scope: Scope
    public let emptyState: EmptyState?
    public let items: [DispatchPromptItem]

    public var isEmpty: Bool { items.isEmpty }

    public init(
        projectID: ProjectID,
        scope: Scope,
        emptyState: EmptyState?,
        items: [DispatchPromptItem]
    ) {
        self.projectID = projectID
        self.scope = scope
        self.emptyState = emptyState
        self.items = items
    }
}

/// One dispatch row in the prompt index.
public struct DispatchPromptItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let recordID: String?
    public let pass: RunPass
    public let round: Int?
    public let routeTry: Int?
    public let route: String
    public let time: Date
    public let session: DispatchSession
    public let state: DispatchPromptIndex.EntryState
    public let family: PromptFamily?
    public let projectID: ProjectID?
    public let defaultVersion: Int?
    public let projectInstructions: ProjectInstructionsUse?
    public let launch: DispatchLaunch?
    public let nightID: Int64?
    public let featureIssueID: String?
    public let workCardIssueID: String?
    public let cardID: Int64?
    public let attemptID: Int64?
    public let instruction: String?
    public let outputSchema: String?

    public static let resumedSessionNotice =
        "Resumed session: this is the new input for this dispatch. It does not contain the session's earlier " +
        "context, vendor system prompts, automatically loaded repository instructions or tool results."

    public static let copyEvidenceNotice =
        "Prompt text is local diagnostic evidence. It can contain private source, board text and Operator " +
        "instructions. Yellowhammer does not add it to Linear, pull requests, notifications or telemetry. " +
        "After you copy it, where it goes is up to you."

    public init(
        id: String,
        recordID: String?,
        pass: RunPass,
        round: Int?,
        routeTry: Int?,
        route: String,
        time: Date,
        session: DispatchSession,
        state: DispatchPromptIndex.EntryState,
        family: PromptFamily?,
        projectID: ProjectID?,
        defaultVersion: Int?,
        projectInstructions: ProjectInstructionsUse?,
        launch: DispatchLaunch?,
        nightID: Int64?,
        featureIssueID: String?,
        workCardIssueID: String?,
        cardID: Int64?,
        attemptID: Int64?,
        instruction: String?,
        outputSchema: String?
    ) {
        self.id = id
        self.recordID = recordID
        self.pass = pass
        self.round = round
        self.routeTry = routeTry
        self.route = route
        self.time = time
        self.session = session
        self.state = state
        self.family = family
        self.projectID = projectID
        self.defaultVersion = defaultVersion
        self.projectInstructions = projectInstructions
        self.launch = launch
        self.nightID = nightID
        self.featureIssueID = featureIssueID
        self.workCardIssueID = workCardIssueID
        self.cardID = cardID
        self.attemptID = attemptID
        self.instruction = instruction
        self.outputSchema = outputSchema
    }

    public var isResumed: Bool {
        session == .resumed
    }

    public var launchStateDescription: String {
        switch launch {
        case .pending:
            "Launch not confirmed"
        case .launched:
            "Launched"
        case .notLaunched(let cause):
            "Not launched: \(cause)"
        case nil:
            "Unknown"
        }
    }

    public var projectInstructionsDescription: String {
        switch projectInstructions {
        case .absent, nil:
            "Project instructions: none"
        case .revision(let revision):
            "Project instructions: revision \(revision)"
        }
    }
}

/// The result of reading a prompt index from disk.
public enum DispatchPromptIndexRead: Equatable, Sendable {
    case index(DispatchPromptIndex)
    case noSuchCard
    case noSuchAttempt
    case noSuchNight
    case journalMissing
    case journalFailure(String)
}
