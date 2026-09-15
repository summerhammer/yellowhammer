/// The mode a Night runs in. Rehearsal is a mode of a Night, never an environment, a build
/// configuration or a scheme: a Rehearsal Night runs the real Acts with three boundaries removed.
public enum NightMode: String, CaseIterable, Sendable {
    case real
    case rehearsal
}
