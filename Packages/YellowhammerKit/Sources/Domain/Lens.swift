/// The perspective a Round was judged from: a reviewer asked for changes, or the engine-run Check failed.
public enum Lens: String, CaseIterable, Sendable {
    case review
    case check
}
