/// A Feature's derived `rollup_state` over its member Cards (glossary → Roll-up; spec: board-
/// projection/maintain-the-managed-block, second story). Six words, and no other word exists.
public enum RollUpState: String, CaseIterable, Sendable {
    case authoring = "authoring"
    case running = "running"
    case needsYou = "needs you"
    case blocked = "blocked"
    case partialLanding = "partial landing"
    case verified = "verified"
}
