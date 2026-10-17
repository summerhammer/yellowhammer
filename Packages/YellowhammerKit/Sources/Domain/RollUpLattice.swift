/// The Roll-up lattice over a Feature's member Work Cards (glossary → Roll-up; spec: board-projection/
/// overview.md, #roll-up-lattice). A pure function, so the Engine's Managed Block and the app's Pulse both
/// compute the one `rollup_state` rather than two copies of it.
///
/// Two halves, selected by whether every Repo Lane has finished (`lanesPushed`):
/// - running half: `waiting` if any Card waits on you, else `blocked` if any is blocked, else `running`;
/// - closed half: `partial` if any Card waits on you or is blocked; `verified` when every Card is done and
///   Verification passed; otherwise `waiting` (all done, Verification unmet or not recorded).
public enum RollUpLattice {
    /// The Roll-up word and its sentence (without bold markdown or the conflict / no-pull-request suffixes).
    ///
    /// Precondition: `liveCardStates` holds the states of the live (non-Shelved) member Cards only, and is not
    /// empty. The caller handles a Feature with zero Cards and one whose Cards are all Shelved: both need the
    /// Feature Issue's own standing, which this function does not see.
    public static func rollUp(
        liveCardStates: [CardState], lanesPushed: Bool, verificationPassed: Bool, unmetClauseCount: Int?,
        notCheckedClauseCount: Int = 0, mergedFraction: MergedFraction
    ) -> (state: RollUpState, sentence: String) {
        lanesPushed
            ? closedHalf(
                live: liveCardStates, verificationPassed: verificationPassed,
                unmetClauseCount: unmetClauseCount, notCheckedClauseCount: notCheckedClauseCount,
                mergedFraction: mergedFraction
            )
            : runningHalf(live: liveCardStates)
    }

    private static func runningHalf(live: [CardState]) -> (state: RollUpState, sentence: String) {
        let liveCount = live.count
        let doneCount = live.count { $0 == .done }
        let waitingCount = live.count { $0 == .waitingOnYou }
        let blockedCount = live.count { $0 == .blocked }
        let inProgressCount = live.count { $0 == .inProgress }

        let word: RollUpState = waitingCount > 0 ? .waiting : (blockedCount > 0 ? .blocked : .running)
        let top: String
        if waitingCount > 0 {
            top = "\(waitingCount) waiting on you"
        } else if blockedCount > 0 {
            top = "\(blockedCount) blocked"
        } else if inProgressCount > 0 {
            top = "\(inProgressCount) running"
        } else {
            top = "all on track"
        }
        return (word, "\(word.rawValue) · \(doneCount) of \(liveCount) Cards landed · \(top)")
    }

    private static func closedHalf(
        live: [CardState], verificationPassed: Bool, unmetClauseCount: Int?, notCheckedClauseCount: Int,
        mergedFraction: MergedFraction
    ) -> (state: RollUpState, sentence: String) {
        let liveCount = live.count
        let doneCount = live.count { $0 == .done }
        let waitingCount = live.count { $0 == .waitingOnYou }
        let blockedCount = live.count { $0 == .blocked }
        let allDone = live.allSatisfy { $0 == .done }

        let word: RollUpState
        let top: String
        if waitingCount > 0 {
            word = .partial
            top = "\(waitingCount) waiting on you"
        } else if blockedCount > 0 {
            word = .partial
            top = "\(blockedCount) blocked"
        } else if allDone && verificationPassed {
            word = .verified
            top = "all verified"
        } else {
            // All Done without passing Verification is a Feature-level waiting disposition,
            // not a Partial Landing: no live member is Blocked or Waiting on You.
            word = .waiting
            if let unmet = unmetClauseCount {
                var fragments: [String] = []
                if unmet > 0 {
                    fragments.append("\(unmet) clauses unmet")
                }
                if notCheckedClauseCount > 0 {
                    fragments.append("\(notCheckedClauseCount) clauses not checked")
                }
                top = fragments.isEmpty ? "0 clauses unmet" : fragments.joined(separator: ", ")
            } else {
                top = "verification not recorded"
            }
        }

        var slots = ["\(word.rawValue)", "\(doneCount) of \(liveCount) Cards landed"]
        if !mergedFraction.isFullyMerged {
            slots.append(mergedFraction.formatted)
        }
        slots.append(top)
        return (word, slots.joined(separator: " · "))
    }
}
