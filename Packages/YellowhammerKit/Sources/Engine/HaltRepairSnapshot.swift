import Domain
import Foundation
import Journal

/// The draft child a repaired halted Feature's Work Card IS: its issue, and the workflow state it sat in as a
/// draft, which is what a rollback puts it back to.
struct RepairedDraftChild: Equatable {
    let issue: BoardObjectID
    let priorState: BoardObjectID
    /// The scope the Operator declared on the draft.
    let scope: [String]
}

/// A fresh, complete Board snapshot of a halted Feature and all its current children, taken when the Operator
/// moves the Feature Card to Todo (roadmap P22.6; spec: feature-authoring/select-the-next-feature,
/// `#halted-authoring-repair`). It carries each child's identity, revision and supported fields — kind,
/// repository, declared scope, Architectural Brief, Definition of Done — and nothing else: counters, budgets,
/// attempt history, run ids and ownership are never imported from the Board.
///
/// A child the Operator canceled or deleted, or moved out from beneath the Feature Card, is an intentional
/// exclusion: it is left out and never created again. A child created beneath the Feature Card since is in.
public struct HaltRepairSnapshot: Equatable, Sendable {
    public struct Child: Equatable, Sendable {
        public let issue: BoardObjectID
        /// The human identifier (`ENG-123`), or the title when the board gave none: how a diagnostic names it.
        public let label: String
        public let title: String
        /// The exact revision (`updatedAt`) this child was validated at.
        public let revision: Date
        let stateID: BoardObjectID
        let draft: CardDraft?
        let scope: [String]
        /// Why this child cannot be read as a Work Card draft; empty when it can.
        public let problems: [String]
    }

    public let haltID: Int64
    public let feature: BoardObjectID
    public let featureRevision: Date
    let featureDefinitionOfDone: [DefinitionOfDoneClauseDraft]
    public let children: [Child]
    public let excluded: [BoardObjectID]

    /// Every problem, each naming its child.
    public var problems: [String] {
        children.flatMap { child in child.problems.map { "\(child.label): \($0)" } }
    }

    /// The breakdown the children make: the Feature's own Definition of Done and one Card per child, in order.
    var breakdown: FeatureBreakdown {
        FeatureBreakdown(definitionOfDone: featureDefinitionOfDone, cards: children.compactMap(\.draft))
    }

    /// The children's declared scopes by Card title, for the contract-overlap floor.
    var scopes: [String: [String]] {
        Dictionary(children.compactMap { child in child.draft.map { ($0.title, child.scope) } }) { first, _ in first }
    }

    /// Each child's identity and revision, the Feature's revision, and the issues left out: two snapshots with
    /// equal fingerprints saw the same Board.
    var fingerprint: [String] {
        ["feature:\(feature.rawValue)@\(featureRevision.timeIntervalSince1970)"]
            + children.map { "child:\($0.issue.rawValue)@\($0.revision.timeIntervalSince1970)#\($0.stateID.rawValue)" }
    }

    var draftChildren: [RepairedDraftChild?] {
        children.map { RepairedDraftChild(issue: $0.issue, priorState: $0.stateID, scope: $0.scope) }
    }

    /// The exact revision of every child (and the Feature Card), keyed by issue id.
    var admittedRevisions: [String: Date] {
        Dictionary(uniqueKeysWithValues: children.map { ($0.issue.rawValue, $0.revision) })
    }

    // MARK: - Taking

    /// Reads the Feature Card, scans the Board for children beneath it that the Delta Read has not admitted yet,
    /// and reads every candidate child again. Nil when the Feature Card cannot be read.
    static func take(
        halt: AuthoringHaltRecord, checkpoint: AuthoringHaltCheckpoint, context: ActContext
    ) async throws -> HaltRepairSnapshot? {
        guard let board = context.board, let featureText = halt.issueID else { return nil }
        let feature = BoardObjectID(rawValue: featureText)
        guard let featureObject = try await board.reading.issue(feature) else { return nil }
        let journal = context.journal
        try await admitUnseenChildren(of: feature, halt: halt, board: board, journal: journal)
        var children: [Child] = []
        var excluded: [BoardObjectID] = []
        for row in try journal.authoringHaltDrafts(haltID: halt.id) {
            guard let issueText = row.issueID else { continue }
            let issue = BoardObjectID(rawValue: issueText)
            guard let object = try await board.reading.issue(issue), object.archivedAt == nil, !object.isTrashed,
                  object.workflowState.category != .shelved, object.parent == feature
            else {
                excluded.append(issue)
                continue
            }
            children.append(child(from: object))
        }
        return HaltRepairSnapshot(
            haltID: halt.id, feature: feature, featureRevision: featureObject.updatedAt,
            featureDefinitionOfDone: checkpoint.breakdown?.definitionOfDone ?? [], children: children,
            excluded: excluded
        )
    }

    /// Children created beneath the Feature Card since the Delta Read last ran: a complete read of what changed
    /// on the Board since the halt was recorded, so the snapshot never misses one.
    private static func admitUnseenChildren(
        of feature: BoardObjectID, halt: AuthoringHaltRecord, board: ActBoard, journal: JournalStore
    ) async throws {
        var cursor: BoardCursor?
        let since = halt.createdAt.addingTimeInterval(-60)
        repeat {
            let page = try await board.reading.objects(updatedSince: since, after: cursor)
            for object in page.objects where object.parent == feature && object.archivedAt == nil && !object.isTrashed {
                guard try journal.card(issueID: object.id.rawValue) == nil else { continue }
                try journal.admitAuthoringHaltChild(
                    haltID: halt.id, issueID: object.id.rawValue, title: object.title, revision: object.updatedAt
                )
            }
            cursor = page.nextCursor
        } while cursor != nil
    }

    // MARK: - Reading one child

    private static func child(from object: BoardObject) -> Child {
        let label = object.key.isEmpty ? "'\(object.title)'" : "\(object.key) '\(object.title)'"
        var problems: [String] = []
        let parts: ManagedBlockFence.Parts
        switch ManagedBlockFence.parts(of: object.description) {
        case .success(let value): parts = value
        case .failure(let failure):
            return Child(
                issue: object.id, label: label, title: object.title, revision: object.updatedAt,
                stateID: object.workflowState.id, draft: nil, scope: [],
                problems: ["its Managed Block cannot be read (\(failure)); restore the delimiters"]
            )
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        let lines = parts.block.components(separatedBy: "\n")
        let masked = ArchitecturalBriefProseRegion.structureMasks(lines)
        func field(_ prefix: String) -> String? {
            lines.indices.lazy.filter { !masked.contains($0) }
                .map { lines[$0].trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(prefix) }
                .map { $0.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "` ")) }
        }
        let repository = field("**Repository:**")
        let kind = field("**Kind:**").flatMap(Kind.init)
        if repository?.isEmpty != false { problems.append("it names no repository (a `**Repository:**` line)") }
        if kind == nil { problems.append("it names no valid Kind (a `**Kind:**` line such as `impl.boilerplate`)") }
        for invalid in parsed.invalid { problems.append("\(invalid.field): \(invalid.reason)") }
        for reference in parsed.transcriptions {
            if let failure = reference.failure { problems.append("a contract reference cannot be read: \(failure)") }
        }
        let tail = parts.preservedProse.range(of: ManagedBlockFence.end).map {
            String(parts.preservedProse[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let draft: CardDraft? = problems.isEmpty ? kind.flatMap { kind in
            repository.map { repository in
                CardDraft(
                    repository: repository, kind: kind, title: object.title, unitOfWork: tail,
                    brief: parsed.briefProse ?? "",
                    definitionOfDone: parsed.clauses.map {
                        DefinitionOfDoneClauseDraft(text: $0.text, citation: SpecCitation($0.citation ?? ""))
                    },
                    contracts: parsed.transcriptions.map {
                        ContractDraft(repository: $0.repository, paths: $0.paths, ranges: $0.ranges, symbol: $0.symbol)
                    }
                )
            }
        } : nil
        return Child(
            issue: object.id, label: label, title: object.title, revision: object.updatedAt,
            stateID: object.workflowState.id, draft: draft, scope: parsed.scope ?? [], problems: problems
        )
    }
}
