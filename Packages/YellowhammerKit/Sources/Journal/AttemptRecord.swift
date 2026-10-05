import Domain
import Foundation

// Split out of Attempt.swift to keep that file under the length limit: the record types
// ``AttemptHistory`` (in Attempt.swift) is built from.

/// One judgement pass over an Attempt's work, from a Lens (`review` or `check`), with its verdict, any
/// requested changes, and the commit it judged.
public struct RoundRecord: Equatable, Sendable {
    public let id: Int64
    public let attemptID: Int64
    public let lens: Lens
    public let verdict: String
    public let requestedChanges: String?
    public let judgedCommit: String?
    public let createdAt: Date
}

/// One dispatch of a Card to a Route, with the Rounds judged over its work. An open Attempt (`endedAt`
/// is `nil`) with no live run behind it is what a killed invocation leaves: classifying it
/// (Crashed-Unknown or otherwise) is a later phase's work, so this record only reports it.
public struct AttemptRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let budgetEpoch: Int
    public let route: Route
    public let classification: String?
    public let result: String?
    public let consumedHow: String?
    public let checkDeclaredNone: Bool
    /// How this Attempt's Route was selected: `entry`, `fallback:<n>` or `override`; nil for an
    /// Attempt recorded before P7.7, or through the untyped ``JournalStore/recordAttempt`` overload.
    public let routeSource: String?
    /// The Override pinned in triage at the moment this Attempt was recorded (`Override.description`),
    /// or nil when none was pinned (routing/exclude-tried-routes-on-retry, P7.7).
    public let overridePin: String?
    public let startedAt: Date
    public let endedAt: Date?
    public let rounds: [RoundRecord]
    /// `refs/yellowhammer/attempts/<Feature Branch name>/<attempt id>`: this Attempt's own commits
    /// plus any WIP commit, preserved before a reset moved the Feature Branch tip away from them
    /// (Attempt, Block and Reset Ruling 2026-09-19, OQ60). Nil when nothing was preserved.
    public let preservedRef: String?
    /// The Feature Branch tip `preservedRef` points at, just before the reset. Nil alongside `preservedRef`.
    public let preservedCommit: String?

    /// Whether this Attempt has not yet ended. By invariant, a Card has at most one open Attempt.
    public var isOpen: Bool { endedAt == nil }
}
