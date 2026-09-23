import Domain
import Journal

/// The mainline stamps a banked reply is recorded with (roadmap P11.3): one Repo name per Repo the
/// Card touches. Today that is exactly ``CardRecord/repository``; kept as its own function so a Card
/// that later touches more than one Repo only changes this.
enum BankedReplyStamps {
    /// The Repo names to stamp `card` with — what is passed to ``forCard(_:mainlines:)`` to compute
    /// fresh stamps for a first bank, and what ``forAcknowledgement(card:stored:)`` walks to build the
    /// acknowledgement from whatever the Journal actually stored.
    static func repositories(for card: CardRecord) -> [String] {
        [card.repository]
    }

    /// Fresh stamps for a first bank, from this run's own resolved mainlines. Never used to build the
    /// acknowledgement directly — the Journal's own idempotent bank may have stored a different (or
    /// resolved-then, unresolved-now) set on a prior run, and that stored set is what always drives the
    /// acknowledgement (``forAcknowledgement(card:stored:)``).
    static func forCard(_ card: CardRecord, mainlines: ResolvedMainlines) -> [MainlineStamp] {
        repositories(for: card).map { repository in
            MainlineStamp(repository: repository, commit: mainlines[repository]?.commit)
        }
    }

    /// One stamp per Repo `card` touches, built from what the Journal actually stored
    /// (``JournalStore/bankCardReply(id:stamps:nightID:act:runID:now:)``'s own return), so a retry
    /// after the first bank always reports the same commits it first banked with. A Repo with no
    /// stored row (the mainline could not be resolved at banking time) renders as unresolved.
    static func forAcknowledgement(card: CardRecord, stored: [MainlineStamp]) -> [MainlineStamp] {
        let storedCommits: [String: String] = stored.reduce(into: [:]) { result, stamp in
            if let commit = stamp.commit {
                result[stamp.repository] = commit
            }
        }
        return repositories(for: card).map { repository in
            MainlineStamp(repository: repository, commit: storedCommits[repository])
        }
    }
}
