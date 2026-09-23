/// The one stored marker of a Night's outcome — not the Night Summary's `**Verdict:**` line itself.
///
/// The Night Summary's verdict line (roadmap P12.1; `Engine.NightSummary.verdictLine(night:journal:)`)
/// is computed at render time from the Journal's event table, never stored: an older app reading a
/// newer Journal must still be able to decode `night.verdict`, so this column never grows a case to
/// match the line's richer vocabulary. `idle` is the one case ever written — the author Act finding
/// nothing selectable (`AuthoringNoWorkAvailable`, OQ13) — and the verdict line reads it back only to
/// tell "did not advance — idle" from every other quiet Night.
public enum NightVerdict: String, CaseIterable, Sendable {
    case idle
}
