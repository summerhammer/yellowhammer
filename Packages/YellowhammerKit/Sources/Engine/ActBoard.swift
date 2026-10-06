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

    public init(
        reading: any Board, writing: any BoardWriting, provisioning: any BoardProvisioning,
        tokenRefreshes: AppInstallationTokenRefreshLog? = nil,
        installation: AppInstallationLabel? = nil
    ) {
        self.tokenRefreshes = tokenRefreshes
        self.installation = installation
        self.reading = reading
        self.writing = writing
        self.provisioning = provisioning
    }
}
