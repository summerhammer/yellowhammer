/// One page of a board read.
public struct BoardPage: Equatable, Sendable {
    public var objects: [BoardObject]
    /// Where the next page starts; nil when there is no further page.
    public var nextCursor: BoardCursor?

    public init(objects: [BoardObject], nextCursor: BoardCursor?) {
        self.objects = objects
        self.nextCursor = nextCursor
    }
}
