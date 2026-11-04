import Domain

/// The recorded facts needed to decide release of a held Worktree.
struct HeldPinFacts {
    let recordedCommit: String?
    let branch: FeatureBranch?
    let path: String
}

/// The shared release decision for a gone or non-git Worktree, after reading its main-clone Feature Branch.
/// Callers report a new pin before applying the failure, using their own Journal event and comment kind.
struct HeldWorktreeVerdict {
    let detail: String?
    let report: (ref: String, unpublished: UnpublishedHead)?
    let failure: (body: String, keySuffix: String)?

    static func evaluate(
        step: UnpublishedPinDecision.MainCloneBranchStep, isGone: Bool, held: HeldPinFacts,
        repository: String, moment: LandFailureComment.Moment
    ) -> HeldWorktreeVerdict {
        let detail: String?
        let report: (ref: String, unpublished: UnpublishedHead)?
        let pinRef: String?
        switch step {
        case .notNeeded, .noFeatureBranch:
            (detail, report, pinRef) = (nil, nil, nil)
        case .absent:
            let name = held.branch.map { " `\($0.rawValue)`" } ?? ""
            detail = "nothing was pinned: the Feature Branch\(name) does not resolve in the main clone"
            (report, pinRef) = (nil, nil)
        case .alreadyPinned(let ref):
            (detail, report, pinRef) = ("already pinned at \(ref)", nil, ref)
        case .pinned(let ref, let unpublished):
            (detail, report, pinRef) = ("pinned \(unpublished.head.prefix(7)) at \(ref)", (ref, unpublished), ref)
        case .failed(let reason):
            let comment = LandFailureComment.pinFailed(
                subject: held.branch.map(PinSubject.featureBranch) ?? .worktreeHead, repository: repository,
                reason: reason, recordedCommit: held.recordedCommit, moment: moment
            )
            return HeldWorktreeVerdict(detail: nil, report: nil, failure: comment)
        }
        let failure = isGone ? nil : LandFailureComment.notGitWorktree(
            repository: repository, path: held.path, pinRef: pinRef, moment: moment
        )
        return HeldWorktreeVerdict(detail: detail, report: report, failure: failure)
    }
}
