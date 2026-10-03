import Domain
import Foundation
import Journal

/// The fire-and-forget local-notification orchestration around an Act's life (roadmap P12.5,
/// morning-report/notify-the-operator-of-exceptions, Decision Gates Ruling G-10). Nothing here ever
/// throws: `runUnderLease` calls both entry points as best-effort steps, and a failure to post is
/// recorded as a `notificationDeliveryFailed` event and otherwise ignored.
extension EngineInvocation {
    /// Reported only, never acted on: a Roll-up failure must not fail the Act — except an authorization
    /// failure, which halts like any other board call (P17.5, item 1).
    func maintainRollUps(night: NightRecord, outbox: Outbox?) async throws {
        _ = try await bestEffort {
            try await FeatureRollUpMaintenance.maintainRollUps(night: night, journal: journal, outbox: outbox)
        }
    }

    /// The Act's first Linear call, before the Night Card, the trigger, or any work (roadmap P17.5) —
    /// so a refused identity halts before any board work is attempted, and this Night spends none of
    /// `unanswered_nights_max` (no clock has advanced yet). A non-auth failure here (network, etc.) is
    /// not treated as a halt: it is ignored, and the Night Card open right after this call meets the
    /// same error on its own terms.
    func authorizationPreflight() async throws {
        guard let board else { return }
        do {
            _ = try await board.reading.identity()
        } catch {
            if error.isLinearAuthorizationFailure { throw error }
        }
    }

    /// Closes the Night and completes its Night Card when this Act closes it, then posts `.closed` —
    /// only once that completion is recorded on the Night Card, and before anything later can throw,
    /// so a Night whose close is followed by a failure is reported both closed and halted.
    func closeNightIfNeeded(
        _ night: NightRecord, card: NightCardMaintenance?, outbox: Outbox?
    ) async throws {
        guard closesNight, night.isOpen else { return }
        try journal.closeNight(id: night.id, reason: .nightEnd, act: act, runID: runID)
        // Completion needs the closed Night's completedAt and verdict.
        if let card, let closed = try journal.night(id: night.id) {
            _ = try await card.acceptCompletion(night: closed)
            _ = try await card.deliverCompletion(night: closed)
            await notifyClosed(night: closed)
            // The un-adopted-Cards figure changes every Night regardless of whether the Card was
            // touched, so its Managed Block header is refreshed here too — never lets a refresh
            // failure fail the Night's own completion, which has already happened above.
            if let outbox {
                // Never lets a refresh failure fail the Night's own completion, already recorded above —
                // except an authorization failure, which is rethrown so the Act halts on it (P17.5).
                _ = try await bestEffort {
                    try await UnadoptedCardRefresh.refresh(
                        night: closed, journal: journal, outbox: outbox, runID: runID
                    )
                }
            }
        }
        if let board, let outbox, let (feature, cycleID) = try journal.inFlightFeature() {
            _ = try await FeatureSettleGesture.resetSettleState(
                feature: feature, cycleID: cycleID, nightID: night.id, board: board, outbox: outbox
            )
        }
    }

    /// Posts `.closed`. Called only from `closeNightIfNeeded`, right after this Act's own completion of
    /// the Night Card is recorded, so there is nothing to gate here beyond that.
    func notifyClosed(night: NightRecord) async {
        await notify(.closed, notification: "closed", night: night)
    }

    /// Posts `.halted(reason:)` from `runUnderLease`'s catch, after `.actIncomplete` is appended. The
    /// event is written to the Night Card first, as a comment through the Outbox — the same durability
    /// every other board write gets — and only once that succeeds is the local notification posted.
    /// A stand-down before `runUnderLease` (another run holds the Lease) never reaches this: it is
    /// thrown before a Night Card can exist for this run.
    ///
    /// OQ71 (Halted-Without-Night-Card Notification Ruling): when there is no Night Card to record on
    /// (none open, or the halted comment write is aborted or permanently failed), the local notification
    /// still posts — as `.haltedUnrecorded`, not the ordinary `.halted(reason:)` — because nothing else
    /// tells the Operator this Night halted. A pending/deferred write still counts as "on the Night Card
    /// first", unchanged.
    func notifyHalted(
        reason: String, night: NightRecord, nightCard: NightCardMaintenance?, outbox: Outbox?
    ) async {
        guard board != nil else { return }
        guard let outbox, nightCard != nil, let issueID = night.nightCardIssueID else {
            await notify(.haltedUnrecorded, notification: "halted", night: night)
            return
        }
        guard await recordHaltedComment(reason: reason, issueID: issueID, night: night, outbox: outbox) else {
            await notify(.haltedUnrecorded, notification: "halted", night: night)
            return
        }
        await notify(.halted(reason: Self.collapsed(reason)), notification: "halted", night: night)
    }

    /// An authorization halt (roadmap P17.5, Linear App Installation Ruling items 5, 12, 13) never
    /// attempts the halted Night Card comment at all: the identity itself is refused, so that write
    /// would only queue pending behind the same refusal (P17.5, Outbox), and the OQ71
    /// "unrecorded" copy is not used for this cause either — the fix is always the same, whether or
    /// not a Night Card exists. Posts once per Night: a prior `.linearAuthorizationHalted` event for
    /// this `nightID` means a later Act already told the Operator, so this one records only.
    func notifyLinearAuthorizationHalted(night: NightRecord) async {
        let isFirst = (try? journal.events(ofType: .linearAuthorizationHalted))?
            .allSatisfy { $0.nightID != night.id } ?? true
        _ = try? journal.append(.linearAuthorizationHalted, act: act, runID: runID, nightID: night.id)
        guard isFirst else { return }
        await notify(.halted(reason: Self.linearAuthorizationCopy), notification: "halted", night: night)
    }

    /// Names the cause and the fix, whether or not a Night Card could be opened (P17.5): a refused
    /// identity cannot have written one either way, so the message is never conditioned on that.
    private static let linearAuthorizationCopy =
        "Linear refused Yellowhammer's sign-in. Re-run the Linear step: yh setup --install-linear, " +
            "or the Setup view in Yellowhammer.app."

    /// Writes the halted comment through the Outbox. `true` once the write is at least accepted —
    /// applied, already applied, or left pending for a later Act to replay — which is what "recorded
    /// on the Night Card first" means for a write that goes through the Outbox at all.
    private func recordHaltedComment(
        reason: String, issueID: String, night: NightRecord, outbox: Outbox
    ) async -> Bool {
        let key = NightCardMaintenance.haltedKey(nightStart: nightStart, runID: runID)
        let body = "**Night halted:** the `\(act.rawValue)` Act did not complete: \(reason)"
        let write = OutboxWrite(key: key, write: .createComment(issue: BoardObjectID(rawValue: issueID), body: body))
        do {
            switch try await outbox.post(write).outcome {
            case .applied, .alreadyApplied, .deferred:
                return true
            case .aborted, .failed:
                return false
            }
        } catch {
            return false
        }
    }

    private func notify(_ event: ExceptionNotification.Event, notification: String, night: NightRecord) async {
        do {
            try await notifier.post(ExceptionNotification(project: journal.projectID, event: event))
        } catch {
            recordDeliveryFailure(notification: notification, reason: String(describing: error), night: night)
        }
    }

    private func recordDeliveryFailure(notification: String, reason: String, night: NightRecord) {
        _ = try? journal.append(
            .notificationDeliveryFailed(notification: notification, reason: reason),
            act: act, runID: runID, nightID: night.id
        )
    }

    /// The Night Card comment keeps the full reason; the local notification's is a single line
    /// (whitespace runs collapsed), capped so a long thrown-error description does not overrun a
    /// notification banner.
    private static func collapsed(_ reason: String, limit: Int = 200) -> String {
        let singleLine = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return "\(singleLine.prefix(limit))…"
    }

    /// Appends the Act's closing event (`.actEnded`, or `.actIncomplete` on the way out) after each
    /// App Installation token-pair refresh the board attempted this Act, so the record precedes it.
    /// The log is drained, so each record lands exactly once. Best-effort, like every other event;
    /// every Linear call an Act makes happens after its Night opened, so the Night is always known.
    func appendClosing(_ closing: JournalEvent, night: NightRecord) {
        for refresh in board?.tokenRefreshes?.drain() ?? [] {
            _ = try? journal.append(.appInstallationTokenRefresh(refresh), act: act, runID: runID, nightID: night.id)
        }
        _ = try? journal.append(closing, act: act, runID: runID, nightID: night.id)
    }
}
