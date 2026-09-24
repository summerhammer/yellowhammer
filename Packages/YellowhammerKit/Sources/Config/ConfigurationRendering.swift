import Domain
import Foundation

/// Renders configuration values back to the TOML shapes ``ConfigurationDecoding`` accepts, for setup to
/// write `~/.config/yellowhammer/config.toml` and `projects/<id>.toml` with the spec's defaults spelled
/// out (bounds/bound-unanswered-nights: "Initial setup sets `unanswered_nights_max = 3` in each
/// Project's `[limits]` section").
enum ConfigurationRendering {
    /// A TOML basic string: `\` and `"` are escaped, along with the control characters that must be
    /// (backslash-escaped) rather than written literally.
    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    /// A quoted TOML key, used for table headers whose name may not be a bare key (such as a CLI
    /// Adapter name with a space).
    static func quotedKey(_ string: String) -> String {
        quoted(string)
    }

    /// A route rendered as the `"cli/model/effort"` shorthand ``ConfigurationDecoding/route(_:path:defaultEffort:)``
    /// accepts.
    static func route(_ route: Route) -> String {
        quoted(route.description)
    }

    static func kindLine(_ kind: Kind) -> String? {
        kind == .any ? nil : "kind = \(quoted(kind.description))"
    }

    static func repoRoleLine(_ match: RepoRoleMatch) -> String? {
        switch match {
        case .any: nil
        case .role(let role): "repo_role = \(quoted(role.rawValue))"
        }
    }

    /// One `[[routing]]` entry, in the key order the decoder reads: `kind`, `repo_role`, `route`,
    /// `fallbacks`.
    static func routingEntry(_ entry: RoutingEntry) -> String {
        var lines = ["[[routing]]"]
        if let kindLine = kindLine(entry.kind) { lines.append(kindLine) }
        if let repoRoleLine = repoRoleLine(entry.repoRole) { lines.append(repoRoleLine) }
        lines.append("route = \(route(entry.route))")
        if !entry.fallbacks.isEmpty {
            let items = entry.fallbacks.map { route($0) }.joined(separator: ", ")
            lines.append("fallbacks = [\(items)]")
        }
        return lines.joined(separator: "\n")
    }

    static func routingSection(_ entries: [RoutingEntry]) -> [String] {
        entries.map { routingEntry($0) }
    }
}

extension MachineConfiguration {
    /// Renders `[linear]`, `[github]`, one `[cli.<name>]` table per declared adapter and the base
    /// Routing Table, in the shape ``MachineConfigurationDecoder`` reads back.
    public var renderedTOML: String {
        var sections: [String] = []

        var linear = ["[linear]", "credential = \(ConfigurationRendering.quoted(linearCredential.rawValue))"]
        linear.append("client_id = \(ConfigurationRendering.quoted(linearClientID))")
        if let operatorIdentity {
            linear.append("operator = \(ConfigurationRendering.quoted(operatorIdentity.rawValue))")
        }
        sections.append(linear.joined(separator: "\n"))

        sections.append("[github]\ncredential = \(ConfigurationRendering.quoted(gitHubCredential.rawValue))")

        for adapter in cliAdapters {
            var lines = ["[cli.\(ConfigurationRendering.quotedKey(adapter.name))]"]
            if let executable = adapter.executable {
                lines.append("executable = \(ConfigurationRendering.quoted(executable))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append(contentsOf: ConfigurationRendering.routingSection(routingTable))

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line,
    /// including comments. Replaces an existing `[linear].operator` line, or inserts one right after the
    /// `[linear]` header when absent. Applying it twice equals applying it once.
    public static func settingOperator(_ operatorIdentity: BoardObjectID, inFileText text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let newLine = "operator = \(ConfigurationRendering.quoted(operatorIdentity.rawValue))"

        guard let linearHeaderIndex = lines.firstIndex(where: { isTableHeader($0, named: "linear") }) else {
            return text
        }

        var searchIndex = linearHeaderIndex + 1
        while searchIndex < lines.count, !isAnyTableHeader(lines[searchIndex]) {
            if isKeyAssignment(lines[searchIndex], key: "operator") {
                lines[searchIndex] = newLine
                return lines.joined(separator: "\n")
            }
            searchIndex += 1
        }

        lines.insert(newLine, at: linearHeaderIndex + 1)
        return lines.joined(separator: "\n")
    }

    private static func isTableHeader(_ line: String, named name: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "[\(name)]"
    }

    private static func isAnyTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }

    private static func isKeyAssignment(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equalsIndex = trimmed.firstIndex(of: "=") else { return false }
        let lhs = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
        return lhs == key
    }
}

extension ProjectConfiguration {
    /// Renders the Project's identity, Repos, `[limits]` (all six Bounds, explicit) and `[schedule]`
    /// (all three keys, explicit) — see the spec citation on ``ConfigurationRendering`` — plus an
    /// optional `[github]` override and any Routing Table overrides.
    public var renderedTOML: String {
        var sections: [String] = []

        var top = ["id = \(ConfigurationRendering.quoted(id.rawValue))"]
        top.append("name = \(ConfigurationRendering.quoted(name))")
        top.append("linear_project = \(ConfigurationRendering.quoted(linearProject))") // glossary:ignore GL001
        if let specSource {
            top.append("spec_source = \(ConfigurationRendering.quoted(specSource))")
        }
        sections.append(top.joined(separator: "\n"))

        if let gitHubCredential {
            sections.append("[github]\ncredential = \(ConfigurationRendering.quoted(gitHubCredential.rawValue))")
        }

        for repo in repos {
            sections.append(renderedRepo(repo))
        }

        sections.append(renderedLimits)
        sections.append(renderedSchedule)

        sections.append(contentsOf: ConfigurationRendering.routingSection(routingOverrides))

        return sections.joined(separator: "\n\n") + "\n"
    }

    private func renderedRepo(_ repo: RepoDeclaration) -> String {
        var lines = ["[[repos]]"]
        lines.append("name = \(ConfigurationRendering.quoted(repo.name))")
        lines.append("path = \(ConfigurationRendering.quoted(repo.path))")
        lines.append("role = \(ConfigurationRendering.quoted(repo.role.rawValue))")
        lines.append("check = \(ConfigurationRendering.quoted(repo.check.description))")
        if !repo.protectedPaths.isEmpty {
            let items = repo.protectedPaths.map { ConfigurationRendering.quoted($0) }.joined(separator: ", ")
            lines.append("protected_paths = [\(items)]")
        }
        return lines.joined(separator: "\n")
    }

    private var renderedLimits: String {
        """
        [limits]
        review_rounds_max = \(bounds.reviewRoundsMax)
        attempts_per_card = \(bounds.attemptsPerCard)
        unanswered_nights_max = \(bounds.unansweredNightsMax)
        reselections_max = \(bounds.reselectionsMax)
        consecutive_refusals_max = \(bounds.consecutiveRefusalsMax)
        failed_adoptions_max = \(bounds.failedAdoptionsMax)
        """
    }

    private var renderedSchedule: String {
        """
        [schedule]
        night_start = \(ConfigurationRendering.quoted(schedule.nightStart.description))
        night_end = \(ConfigurationRendering.quoted(schedule.nightEnd.description))
        build_every_minutes = \(schedule.buildEveryMinutes)
        """
    }
}
