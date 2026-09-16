import Foundation

/// Machine-owned region inside the brief holding one contract transcribed from another repository's mainline.
public struct TranscriptionBlock: Equatable, Sendable {
    public var repository: String
    public var paths: [String]
    public var symbol: String?
    public var mainlineCommit: String?  // nil when Operator-supplied
    public var content: String
    public var contentHash: String
    public var authorSupplied: Bool
    public var authorSuppliedNight: NightStart?  // "Operator-supplied, as of the Night the edit was seen"

    public init(
        repository: String,
        paths: [String],
        symbol: String? = nil,
        mainlineCommit: String? = nil,
        content: String,
        contentHash: String,
        authorSupplied: Bool,
        authorSuppliedNight: NightStart? = nil
    ) {
        self.repository = repository
        self.paths = paths
        self.symbol = symbol
        self.mainlineCommit = mainlineCommit
        self.content = content
        self.contentHash = contentHash
        self.authorSupplied = authorSupplied
        self.authorSuppliedNight = authorSuppliedNight
    }
}

/// The architectural brief carried by a Card, giving approach before dispatch.
public struct ArchitecturalBrief: Equatable, Sendable {
    public var prose: String
    public var transcriptions: [TranscriptionBlock]

    public init(prose: String, transcriptions: [TranscriptionBlock]) {
        self.prose = prose
        self.transcriptions = transcriptions
    }
}
