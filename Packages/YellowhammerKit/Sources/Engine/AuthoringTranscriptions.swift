import Domain
import Foundation
import Repositories

// Transcribes every contract a breakdown's new Cards name, before anything is accepted into the Outbox
// (roadmap P9.6; spec: feature-authoring/author-an-architectural-brief): a Card that needs a contract
// this author Act cannot read is never authored speculatively — the whole Feature halts, naming every
// repository it could not read, before any board write this transaction would otherwise make.

/// Transcribes one contract from another repository's merged mainline, without the author Act needing
/// to know it is talking to git — mirrors ``CitationResolving``.
public protocol ContractTranscribing: Sendable {
    func transcribe(
        _ contract: ContractDraft, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async throws -> TranscriptionBlock
}

extension MainlineReader: ContractTranscribing {
    public func transcribe(
        _ contract: ContractDraft, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async throws -> TranscriptionBlock {
        try await transcribe(
            paths: contract.paths, repository: contract.repository, in: projectRepositories,
            symbol: contract.symbol, mainlines: mainlines
        )
    }
}

/// What transcribing a ``FeatureBreakdown``'s drafted contracts found: the blocks to carry in each new
/// Card's brief, or every contract that could not be read.
struct AuthoringTranscriptionResult {
    /// Per-Card transcribed blocks, aligned by index with the breakdown's `cards`.
    let cardTranscriptions: [[TranscriptionBlock]]
    /// Every contract that could not be read, across every Card, in draft order.
    let unreadable: [UnreadableContract]

    var isReadable: Bool { unreadable.isEmpty }
}

private enum AuthoringTranscriptionError: Error {
    case noPaths
    case noRepositories
    case unroundtrippable
}

enum AuthoringTranscriptions {
    private static let noRepositoriesReason =
        "this Project has no repositories configured to read contracts against"
    private static let noPathsReason = "the contract names no path to read"
    private static let unroundtrippableReason =
        "the transcribed content contains a line that could not round-trip through the Managed Block"

    /// Transcribes every contract named by the breakdown's new Cards, Card by Card in draft order,
    /// against `context.repositories` and `context.mainlines` — one refresh of the mainlines for the
    /// whole Feature, never re-resolved per read. Never speculative: a nil `context.repositories` makes
    /// every contract unreadable.
    static func resolve(
        _ breakdown: FeatureBreakdown, using transcriber: any ContractTranscribing, context: ActContext
    ) async -> AuthoringTranscriptionResult {
        var unreadable: [UnreadableContract] = []
        var cardTranscriptions: [[TranscriptionBlock]] = []
        for card in breakdown.cards {
            var blocks: [TranscriptionBlock] = []
            for contract in card.contracts {
                do {
                    blocks.append(try await transcribeOne(contract, transcriber: transcriber, context: context))
                } catch {
                    unreadable.append(UnreadableContract(
                        workCardTitle: card.title, repository: contract.repository, paths: contract.paths,
                        reason: reason(for: error)
                    ))
                }
            }
            cardTranscriptions.append(blocks)
        }
        return AuthoringTranscriptionResult(cardTranscriptions: cardTranscriptions, unreadable: unreadable)
    }

    private static func transcribeOne(
        _ contract: ContractDraft, transcriber: any ContractTranscribing, context: ActContext
    ) async throws -> TranscriptionBlock {
        guard !contract.paths.isEmpty else {
            throw AuthoringTranscriptionError.noPaths
        }
        guard let repositories = context.repositories else {
            throw AuthoringTranscriptionError.noRepositories
        }
        let block = try await transcriber.transcribe(contract, in: repositories, mainlines: context.mainlines)
        guard !containsUnroundtrippableLine(block.content) else {
            throw AuthoringTranscriptionError.unroundtrippable
        }
        return block
    }

    /// True when `content` carries a line that would break round-tripping through
    /// ``CardManagedBlockParser`` — the Transcription Block's own end marker, or either Managed Block
    /// fence delimiter. Compared trimmed, as the parser compares them: an indented marker ends a block too.
    private static func containsUnroundtrippableLine(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == TranscriptionBlockLine.endMarker || line == ManagedBlockFence.start
                || line == ManagedBlockFence.end
        }
    }

    private static func reason(for error: Error) -> String {
        switch error {
        case AuthoringTranscriptionError.noPaths:
            return noPathsReason
        case AuthoringTranscriptionError.noRepositories:
            return noRepositoriesReason
        case AuthoringTranscriptionError.unroundtrippable:
            return unroundtrippableReason
        case let readError as MainlineReadError:
            return readError.description
        default:
            return "\(error)"
        }
    }
}
