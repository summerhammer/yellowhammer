import Foundation

/// Machine-owned region inside the brief holding one contract transcribed from another repository's mainline.
public struct TranscriptionBlock: Equatable, Sendable {
    public var repository: String
    public var paths: [String]
    /// The unioned line ranges actually transcribed per path; a path absent here was transcribed whole.
    public var ranges: [String: [LineRange]]
    public var symbol: String?
    /// The local-mainline commit the lines were read at. Nil only for an Operator-edited reference that
    /// names none (never dispatched, so never read).
    public var mainlineCommit: String?
    public var content: String
    public var contentHash: String
    /// `authorSupplied` and `authorSuppliedNight` together are the "Operator-supplied, as of the Night
    /// the edit was seen" label. Independent of `mainlineCommit`: an Operator-supplied block has a commit
    /// once it is read.
    public var authorSupplied: Bool
    public var authorSuppliedNight: NightStart?
    /// The Operator's `Contract:` line exactly as read from the board, for an edited reference NOT YET
    /// READ. Non-nil means the block is unread; the Card shows it verbatim until the read succeeds, so a
    /// rewrite never overwrites an Operator's edit with the old reference.
    public var editedReference: String?

    public init(
        repository: String,
        paths: [String],
        ranges: [String: [LineRange]] = [:],
        symbol: String? = nil,
        mainlineCommit: String? = nil,
        content: String,
        contentHash: String,
        authorSupplied: Bool,
        authorSuppliedNight: NightStart? = nil,
        editedReference: String? = nil
    ) {
        self.repository = repository
        self.paths = paths
        self.ranges = ranges
        self.symbol = symbol
        self.mainlineCommit = mainlineCommit
        self.content = content
        self.contentHash = contentHash
        self.authorSupplied = authorSupplied
        self.authorSuppliedNight = authorSuppliedNight
        self.editedReference = editedReference
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
