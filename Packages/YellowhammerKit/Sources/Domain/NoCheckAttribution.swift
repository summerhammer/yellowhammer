/// Why a `not checked` clause never ran when the cause is the Repo's own configuration: the repository
/// declared `check = none`, so the Engine ran no Check and recorded none. One wording for every place the
/// Operator reads it (the return comment, the merge-closure comment, the Pulse), so the gap points at the
/// Repo's Check command and not at the verifier's sandbox.
public enum NoCheckAttribution {
    /// `` `seshes-darwin` declares `check = none` `` / `` `a` and `b` declare `check = none` ``.
    public static func declaration(repositories: [String]) -> String {
        let names = repositories.map { "`\($0)`" }
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) declares `check = none`"
        case 2: return "\(names[0]) and \(names[1]) declare `check = none`"
        default:
            return "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1]) declare `check = none`"
        }
    }

    /// The suffix for a section heading: `no automated Check configured: …`. Empty repositories give nil.
    public static func headingNote(repositories: [String]) -> String? {
        repositories.isEmpty ? nil : "no automated Check configured: \(declaration(repositories: repositories))"
    }

    /// The Pulse and Inspector hint: names the repositories and where the Check is set.
    public static func hint(repositories: [String]) -> String? {
        repositories.isEmpty
            ? nil
            : "\(declaration(repositories: repositories)); set its Check in the Project's configuration to automate"
    }

    /// The opening `what_was_checked` must lead with for a build or test clause no Check covers.
    public static func verifierLead(repository: String) -> String {
        "Repository \(repository) declares `check = none` in the Project's configuration; "
            + "no automated Check ran during build."
    }
}
