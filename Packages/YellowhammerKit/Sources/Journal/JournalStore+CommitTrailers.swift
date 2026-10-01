import Foundation

extension JournalStore {
    /// The sha of every commit recorded as missing the `Yellowhammer-Card` trailer for this Card, across
    /// all its Attempts. Reads `cardCommitTrailerMissing` events only; it never changes the Card's outcome.
    public func commitsRecordedMissingTrailer(cardID: Int64) throws -> Set<String> {
        var commits: Set<String> = []
        for record in try events(ofType: .cardCommitTrailerMissing) {
            guard case .cardCommitTrailerMissing(let recordedCardID, _, _, let commit) = record.event,
                recordedCardID == cardID
            else { continue }
            commits.insert(commit)
        }
        return commits
    }
}
