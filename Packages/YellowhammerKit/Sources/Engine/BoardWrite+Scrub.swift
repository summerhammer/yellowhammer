import Domain

extension BoardWrite {
    /// This write with every narrative string passed through `scrub` (OQ146/OQ147, R23). Identifiers,
    /// URLs and the Managed Block `prefix` (a match key, not narrative) are left as they are.
    func scrubbed(by scrub: NarrativeScrub) -> BoardWrite {
        switch self {
        case .createIssue(var draft, let parentKey):
            draft.title = scrub.apply(draft.title)
            draft.description = draft.description.map(scrub.apply)
            return .createIssue(draft, parentKey: parentKey)
        case .createComment(let issue, let body):
            return .createComment(issue: issue, body: scrub.apply(body))
        case .attachLink(let issue, let url, let title):
            return .attachLink(issue: issue, url: url, title: scrub.apply(title))
        case .rewriteManagedBlock(let issue, let rendered):
            return .rewriteManagedBlock(issue: issue, rendered: scrub.apply(rendered))
        case .updateManagedBlockLine(let issue, let prefix, let line):
            return .updateManagedBlockLine(issue: issue, prefix: prefix, line: scrub.apply(line))
        case .updateIssue(let issue, let change, let undo):
            return .updateIssue(
                issue: issue, change: change.scrubbed(by: scrub), undo: undo.map { $0.scrubbed(by: scrub) }
            )
        case .archiveIssue:
            return self
        case .adoptIssue(let issue, let parentKey, let undo):
            return .adoptIssue(issue: issue, parentKey: parentKey, undo: undo.map { $0.scrubbed(by: scrub) })
        }
    }
}

extension BoardIssueChange {
    /// The title and description passed through `scrub`.
    fileprivate func scrubbed(by scrub: NarrativeScrub) -> BoardIssueChange {
        var copy = self
        copy.title = title.map(scrub.apply)
        copy.description = description.map(scrub.apply)
        return copy
    }
}
