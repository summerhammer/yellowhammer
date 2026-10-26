import Foundation

/// Shipped default instructions for Yellowhammer's diagnostic and preflight dispatches.
///
/// Diagnostic dispatches never run real work: they test agent CLI capabilities such as
/// unattended completion, session resumption, and process or state containment.
public enum DiagnosticInstruction {
    /// The scripts a probe's scratch Worktree holds and its instructions tell the CLI to run: the CLI Probe
    /// writes them under these names, so a rename here reaches both.
    public static let holdScriptName = "yh-probe-hold.sh"
    public static let reachScriptName = "yh-probe-reach.sh"

    /// Instruction for unattended probe dispatch and Route Pre-flight.
    public static func unattended(nonce: String) -> String {
        """
        This is an automated Yellowhammer probe, not real work. Do not read or modify any files \
        and do not run any command. Respond immediately with outcome `failed` and reason exactly \
        `\(nonce)`.
        """
    }

    /// Instruction for session resumption probe dispatch.
    public static let resume = """
        This is an automated Yellowhammer probe, not real work. Do not read or modify any files \
        and do not run any command. Respond immediately with outcome `failed` and reason exactly \
        equal to the reason you gave in your previous reply.
        """

    /// Instruction for process containment probe dispatch.
    public static func containment(variant: String) -> String {
        """
        This is an automated Yellowhammer probe, not real work. Using your shell tool, run exactly \
        the command `sh \(holdScriptName) \(variant)` in the foreground from the current working \
        directory, and wait for it to finish. Do nothing else.
        """
    }

    /// Instruction for state containment probe dispatch.
    public static let stateContainment = """
        This is an automated Yellowhammer probe, not real work. Using your shell tool, run exactly \
        the command `sh \(reachScriptName)` once, from the current working directory. Do not modify \
        any files and do nothing else. Respond with outcome `failed` and reason exactly equal to the \
        single line the command printed.
        """
}
