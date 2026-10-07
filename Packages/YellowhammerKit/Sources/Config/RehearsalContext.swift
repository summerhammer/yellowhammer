import Domain
import Foundation

/// Where a Rehearsal Night of one Project runs: a Linear project and a Journal of its own, never the
/// Project's real ones (Rehearsal Context Ruling, OQ149). Isolation holds by construction: a rehearsal
/// shares neither the real Journal's Nights, Features, Refusals and counters nor the real board.
public struct RehearsalContext: Equatable, Sendable {
    /// `[board.linear] rehearsal_project`, reached through the Project's own Board Connection.
    public let linearProject: String
    /// `[rehearsal] journal`, `~` expanded and standardized.
    public let journal: URL
}

/// Why Rehearsal is not available for a Project: `yh rehearse` and `yh <act> --rehearsal` refuse with
/// it before any write, and the app's *Run a rehearsal Night* shows it, in these same words.
public struct RehearsalUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Equatable, Sendable {
        case linearProjectNotDefined
        /// Equal to `[board.linear] project`, which counts as not defined (OQ149 (a)).
        case linearProjectIsTheRealOne
        case journalNotDefined
        /// As written; a path is resolved against nothing, so a relative one counts as not defined.
        case journalNotAbsolute(String)
        /// The Project's real Journal, which counts as not defined (OQ149 (a)).
        case journalIsTheRealOne
        /// Inside the directory every Project's real Journal lives in, where it could be a sibling's.
        case journalAmongRealJournals(directory: String)
    }

    public let projectID: ProjectID
    /// Never empty; the Linear project's reasons first, then the Journal's.
    public let reasons: [Reason]

    public var description: String {
        "Rehearsal is not available for Project \(projectID.rawValue): "
            + reasons.map(Self.describe).joined(separator: "; ") + "."
    }

    private static func describe(_ reason: Reason) -> String {
        switch reason {
        case .linearProjectNotDefined:
            "`[board.linear] rehearsal_project` is not defined"
        case .linearProjectIsTheRealOne:
            "`[board.linear] rehearsal_project` is the Project's own Linear project, which does not count"
        case .journalNotDefined:
            "`[rehearsal] journal` is not defined"
        case .journalNotAbsolute(let path):
            "`[rehearsal] journal` \"\(path)\" is not an absolute path"
        case .journalIsTheRealOne:
            "`[rehearsal] journal` is the Project's own Journal, which does not count"
        case .journalAmongRealJournals(let directory):
            "`[rehearsal] journal` must not be inside \(directory), where every Project's real Journal lives"
        }
    }
}

extension ProjectConfiguration {
    /// This Project's Rehearsal Context, or why Rehearsal is not available for it. Pure: reads nothing
    /// from disk, so the app and the engine reach the same verdict from the same configuration.
    /// `realJournal` is this Project's own Journal file; its directory is where every Project's real
    /// Journal lives.
    public func rehearsalContext(realJournal: URL) throws(RehearsalUnavailable) -> RehearsalContext {
        var reasons: [RehearsalUnavailable.Reason] = []

        let linearProject = rehearsalLinearProject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if linearProject.isEmpty {
            reasons.append(.linearProjectNotDefined)
        } else if linearProject == self.linearProject.trimmingCharacters(in: .whitespacesAndNewlines) {
            reasons.append(.linearProjectIsTheRealOne)
        }

        let journal = Self.rehearsalJournalURL(rehearsalJournal, realJournal: realJournal, reasons: &reasons)

        guard reasons.isEmpty, let journal else {
            throw RehearsalUnavailable(projectID: id, reasons: reasons)
        }
        return RehearsalContext(linearProject: linearProject, journal: journal)
    }

    /// The declared rehearsal Journal's URL, or nil after appending why it does not count.
    private static func rehearsalJournalURL(
        _ declared: String?, realJournal: URL, reasons: inout [RehearsalUnavailable.Reason]
    ) -> URL? {
        guard let declared, !declared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reasons.append(.journalNotDefined)
            return nil
        }
        let expanded = (declared as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            reasons.append(.journalNotAbsolute(declared))
            return nil
        }
        let journal = URL(filePath: expanded, directoryHint: .notDirectory).standardizedFileURL
        let journalsDirectory = realJournal.deletingLastPathComponent()
        if canonicalPath(journal) == canonicalPath(realJournal) {
            reasons.append(.journalIsTheRealOne)
            return nil
        }
        if canonicalPath(journal.deletingLastPathComponent()) == canonicalPath(journalsDirectory) {
            reasons.append(.journalAmongRealJournals(directory: journalsDirectory.path(percentEncoded: false)))
            return nil
        }
        return journal
    }

    /// Compares two spellings of one file: `..`, `.` and symbolic links (such as `/tmp`) resolved.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
