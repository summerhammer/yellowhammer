import Domain

/// The Board Port as one Act holds it: the reading half the Delta Read reads through, the writing half
/// the Outbox lands writes through, and the provisioning half a Night's first Act reads to resolve its
/// ``NightCardScope``. Bound to one Project's Linear project at construction, like every Board Port
/// implementation (ADR-001).
///
/// The Engine never imports an adapter (ADR-001; module boundary rule MB1) — `EngineCommand` is the
/// one place an adapter is wired, and it hands the Engine this struct of protocols instead.
public struct ActBoard: Sendable {
    public let reading: any Board
    public let writing: any BoardWriting
    public let provisioning: any BoardProvisioning

    /// The refresh attempts this Act's board made of the Board Connection's token pair; the Engine
    /// drains it into the Journal. Nil for a board that records none.
    public let tokenRefreshes: AppInstallationTokenRefreshLog?

    /// The Board Connection this board works through. Nil for a board bound through no App
    /// Installation (test fakes).
    public let installation: AppInstallationLabel?

    /// The size every description composed for this board must fit, in the unit the board counts. Nil for a
    /// board that enforces none (test fakes): the Engine holds no board's number of its own (ADR-001).
    public let descriptionBudget: DescriptionBudget?

    /// The Project's Board Mapping (`[board.linear.mapping]`): ids of existing board objects that stand in
    /// for what is provisioned or selected by category. Empty for a Project that declares none.
    public let mapping: BoardMapping

    /// The Project's persisted board-footprint ids and provenance (its Journal). Nil for a board bound with
    /// none (test fakes): the two custom states are then looked up by name and `started` category, as
    /// before P22.8. A real Act always has one, and never adopts a state by name alone.
    public let footprint: (any BoardFootprintStore)?

    public init(
        reading: any Board, writing: any BoardWriting, provisioning: any BoardProvisioning,
        tokenRefreshes: AppInstallationTokenRefreshLog? = nil,
        installation: AppInstallationLabel? = nil,
        descriptionBudget: DescriptionBudget? = nil,
        mapping: BoardMapping = .empty,
        footprint: (any BoardFootprintStore)? = nil
    ) {
        self.mapping = mapping
        self.footprint = footprint
        self.tokenRefreshes = tokenRefreshes
        self.installation = installation
        self.descriptionBudget = descriptionBudget
        self.reading = reading
        self.writing = writing
        self.provisioning = provisioning
    }

    /// This board bound to the Project's Board Mapping and footprint store.
    public func binding(mapping: BoardMapping, footprint: any BoardFootprintStore) -> ActBoard {
        ActBoard(
            reading: reading, writing: writing, provisioning: provisioning, tokenRefreshes: tokenRefreshes,
            installation: installation, descriptionBudget: descriptionBudget, mapping: mapping,
            footprint: footprint
        )
    }
}
