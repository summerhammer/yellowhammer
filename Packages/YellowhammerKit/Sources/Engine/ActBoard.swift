import Domain

/// The Board Port as one Act holds it: the writing half the Outbox lands writes through, and the
/// provisioning half a Night's first Act reads to resolve its ``NightCardScope``. Bound to one
/// Project's Linear project at construction, like every Board Port implementation (ADR-001).
///
/// The Engine never imports an adapter (ADR-001; module boundary rule MB1) — `EngineCommand` is the
/// one place an adapter is wired, and it hands the Engine this struct of protocols instead.
public struct ActBoard: Sendable {
    public let writing: any BoardWriting
    public let provisioning: any BoardProvisioning

    public init(writing: any BoardWriting, provisioning: any BoardProvisioning) {
        self.writing = writing
        self.provisioning = provisioning
    }
}
