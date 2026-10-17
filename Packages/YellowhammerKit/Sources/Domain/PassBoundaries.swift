/// The boundary every pass's instruction states, worded once so no renderer drifts from another
/// (issue #546). An agent pass read Yellowhammer's own state, took the Operator's Linear token out of
/// the login Keychain and called the vendor API with it. The CLI Adapter contains what it can (see
/// `ClaudeCodeAdapter`); this is the part the prompt owns.
public enum PassBoundaries {
    /// The `## Boundaries` section, placed just before the Result contract in every renderer.
    public static let section = "## Boundaries\n\n\(statement)"

    /// The boundary statement itself.
    public static let statement =
        "Everything this pass needs is in this instruction and the repositories it names. Do not read "
        + "Yellowhammer's own state — its configuration directory, Journals, Ledger, run directories or "
        + "their backups — and do not read the macOS Keychain. Do not call Linear, GitHub or any other "
        + "vendor API yourself, with any credential: Yellowhammer alone writes the board and opens pull "
        + "requests. If something you need is missing, say so in your result instead of looking for it."
}
