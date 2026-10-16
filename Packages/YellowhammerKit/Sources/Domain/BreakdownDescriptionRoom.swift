/// How much of the board's description budget a breakdown has to spend on a Work Card, computed by the
/// engine from the same rendering its budget check measures, so the figures the breakdown pass is told are
/// the check's own arithmetic.
public struct BreakdownDescriptionRoom: Equatable, Sendable {
    /// The room left in one working repository's Work Card.
    public struct RepositoryRoom: Equatable, Sendable {
        public let repository: String
        /// What the budget leaves a Card in this repository after the rest of the Managed Block, for the
        /// Card's `kind`, brief, contract references, Definition of Done clauses and unit of work.
        public let room: Int

        public init(repository: String, room: Int) {
            self.repository = repository
            self.room = room
        }
    }

    public let budget: DescriptionBudget
    /// In the order the repositories were given (the Project's Repositories order).
    public let rooms: [RepositoryRoom]
    /// The cost of one Definition of Done clause beyond its text and citation.
    public let clauseOverhead: Int
    /// The cost of one contract reference beyond the repository, paths, ranges and symbol it names.
    public let referenceOverhead: Int
    /// The cost of each path a contract reference names, beyond twice the path's length: the separator
    /// between the paths in the hidden stamp, and the backticks and separator in the visible line.
    public let pathOverhead: Int

    public init(
        budget: DescriptionBudget, rooms: [RepositoryRoom], clauseOverhead: Int, referenceOverhead: Int,
        pathOverhead: Int
    ) {
        self.budget = budget
        self.rooms = rooms
        self.clauseOverhead = clauseOverhead
        self.referenceOverhead = referenceOverhead
        self.pathOverhead = pathOverhead
    }
}
