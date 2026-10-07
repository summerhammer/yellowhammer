import Domain

extension ProvisioningReport {
    /// The messages for every verified item that needs a fix before an Act can run, in report order —
    /// the one rule `yh doctor` (Diagnose the Installation, Check 4) and the Act's board-scope
    /// preflight (OQ85, OQ136) share, so the two never disagree about whether a board is whole.
    ///
    /// An item fails when it is missing, collides with another item's name, or setup's create was
    /// refused. A label whose own group is missing or collides is covered by the group's message, so
    /// a whole group never fails once per child. An invisible Linear project and a team Yellowhammer
    /// is not a member of are the separate membership finding's, not this one's.
    public var unfinishedSteps: [String] {
        unfinishedItems.map(\.message)
    }

    /// ``unfinishedSteps`` with each message's item named on its own — the board scope refusal's
    /// notification names the items without the fix text (OQ85).
    public var unfinishedItems: [UnfinishedItem] {
        entries.compactMap { entry in
            unfinishedStep(entry).map { UnfinishedItem(item: entry.subject.description, message: $0) }
        }
    }

    /// One item that needs a fix: how it is named (e.g. workflow state `Blocked` (team ENG)) and the
    /// full message that says what is wrong and what to do.
    public struct UnfinishedItem: Equatable, Sendable {
        public var item: String
        public var message: String
    }

    private func unfinishedStep(_ entry: ProvisioningEntry) -> String? {
        switch entry.subject {
        case .linearProject, .team:
            return nil
        case .label(_, let group, let team) where !groupIsPresent(group, team: team):
            return nil
        case .label, .labelGroup, .workflowState:
            break
        }
        switch entry.outcome {
        case .missing(let reason):
            return "\(entry.subject) is missing: \(reason)"
        case .collision:
            let existing = entry.collidesWith ?? "an existing item of the same name"
            return "\(entry.subject) is not provisioned: its name is held by the \(existing); "
                + "rename or delete that one in Linear, then re-run `yh setup`"
        case .permissionRefused(let reason):
            return "\(entry.subject): permission refused (\(reason))"
        case .present, .created, .blocked, .notAMember, .refused:
            return nil
        }
    }

    private func groupIsPresent(_ group: String, team: BoardTeam) -> Bool {
        entries.contains { entry in
            guard case .labelGroup(group, let groupTeam) = entry.subject, groupTeam == team else { return false }
            return entry.outcome == .present
        }
    }
}
