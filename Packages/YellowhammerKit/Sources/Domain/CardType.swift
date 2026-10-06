/// The types of cards Yellowhammer provisions in the `Card Type` label group on Linear
/// (OQ125 "Card Type Label Ruling — 2026-10-05", OQ128 "Board Vocabulary Ruling").
///
/// Mutually exclusive label group in Linear named `Card Type`.
/// The labels are `Feature Card` (on a Feature's issue), `Work Card` (on a Work Card),
/// and `Night Card` (on the Night Card).
public enum CardType: String, CaseIterable, Sendable {
    case featureCard = "Feature Card"
    case workCard = "Work Card"
    case nightCard = "Night Card"
}
