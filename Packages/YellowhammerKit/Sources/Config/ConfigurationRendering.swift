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
    /// accepts when every part is non-empty and none contains `/` (which the shorthand cannot carry);
    /// otherwise the inline-table form `{ cli = "…", model = "…", effort = "…" }`, which the decoder
    /// accepts for any string, including one holding a `/` (such as an OpenRouter model id).
    static func route(_ route: RouteDraft) -> String {
        let parts = [route.cli, route.model, route.effort]
        if parts.allSatisfy({ !$0.isEmpty && !$0.contains("/") }) {
            return quoted(parts.joined(separator: "/"))
        }
        return "{ cli = \(quoted(route.cli)), model = \(quoted(route.model)), effort = \(quoted(route.effort)) }"
    }

    /// `kind = "…"`, omitted when `kind` is `""` (not set — the loader treats that as `*`).
    static func kindLine(_ kind: String) -> String? {
        kind.isEmpty ? nil : "kind = \(quoted(kind))"
    }

    /// `repo_role = "…"`, omitted when `repoRole` is `""` (not set — the loader treats that as any Repo Role).
    static func repoRoleLine(_ repoRole: String) -> String? {
        repoRole.isEmpty ? nil : "repo_role = \(quoted(repoRole))"
    }

    /// One `[[routing]]` entry, in the key order the decoder reads: `kind`, `repo_role`, `route`,
    /// `fallbacks`.
    static func routingEntry(_ entry: RoutingEntryDraft) -> String {
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

    static func routingSection(_ entries: [RoutingEntryDraft]) -> [String] {
        entries.map { routingEntry($0) }
    }

    // MARK: - Project file

    static func renderedRepo(_ repo: RepoDraft) -> String {
        var lines = ["[[repos]]"]
        lines.append("name = \(quoted(repo.name))")
        lines.append("path = \(quoted(repo.path))")
        lines.append("role = \(quoted(repo.role))")
        lines.append("check = \(quoted(repo.check))")
        if !repo.protectedPaths.isEmpty {
            let items = repo.protectedPaths.map { quoted($0) }.joined(separator: ", ")
            lines.append("protected_paths = [\(items)]")
        }
        return lines.joined(separator: "\n")
    }

    /// A Bound rendered as the bare integer when its trimmed text parses as one, so the common case
    /// stays an unquoted TOML integer; otherwise as a quoted string, so the loader reports its own
    /// `typeMismatch` rather than the draft silently coercing (or refusing) a garbage value.
    static func boundValue(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let integer = Int64(trimmed) {
            return String(integer)
        }
        return quoted(string)
    }

    /// All six Bounds, explicit — see the spec citation on ``ConfigurationRendering``.
    static func renderedLimits(_ bounds: BoundsDraft) -> String {
        """
        [limits]
        review_rounds_max = \(boundValue(bounds.reviewRoundsMax))
        attempts_per_card = \(boundValue(bounds.attemptsPerCard))
        unanswered_nights_max = \(boundValue(bounds.unansweredNightsMax))
        reselections_max = \(boundValue(bounds.reselectionsMax))
        consecutive_refusals_max = \(boundValue(bounds.consecutiveRefusalsMax))
        failed_adoptions_max = \(boundValue(bounds.failedAdoptionsMax))
        """
    }

    /// All three `[schedule]` keys, explicit.
    static func renderedSchedule(_ schedule: Schedule) -> String {
        """
        [schedule]
        night_start = \(quoted(schedule.nightStart.description))
        night_end = \(quoted(schedule.nightEnd.description))
        build_every_minutes = \(schedule.buildEveryMinutes)
        """
    }
}

extension MachineConfiguration {
    /// Renders `[linear]`, `[github]`, one `[cli.<name>]` table per declared adapter and the base
    /// Routing Table, in the shape ``MachineConfigurationDecoder`` reads back.
    public var renderedTOML: String {
        renderedTOML(routingTable: routingTable.map(RoutingEntryDraft.init))
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

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line,
    /// including comments. Replaces existing `[linear].workspace`/`.app_user` lines, or inserts them
    /// right after the `[linear]` header when absent (P17.6 writes these once the Installation
    /// succeeds). Applying it twice equals applying it once.
    public static func settingLinearInstallation(
        workspace: BoardObjectID, appUser: BoardObjectID, inFileText text: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let linearHeaderIndex = lines.firstIndex(where: { isTableHeader($0, named: "linear") }) else {
            return text
        }

        var searchIndex = linearHeaderIndex + 1
        var workspaceLineIndex: Int?
        var appUserLineIndex: Int?
        while searchIndex < lines.count, !isAnyTableHeader(lines[searchIndex]) {
            if isKeyAssignment(lines[searchIndex], key: "workspace") {
                workspaceLineIndex = searchIndex
            } else if isKeyAssignment(lines[searchIndex], key: "app_user") {
                appUserLineIndex = searchIndex
            }
            searchIndex += 1
        }

        let workspaceLine = "workspace = \(ConfigurationRendering.quoted(workspace.rawValue))"
        let appUserLine = "app_user = \(ConfigurationRendering.quoted(appUser.rawValue))"

        if let workspaceLineIndex {
            lines[workspaceLineIndex] = workspaceLine
        } else {
            lines.insert(workspaceLine, at: linearHeaderIndex + 1)
            appUserLineIndex = appUserLineIndex.map { $0 + 1 }
        }
        if let appUserLineIndex {
            lines[appUserLineIndex] = appUserLine
        } else {
            // Right after `workspace` if it was just inserted or already present, else right after the header.
            let insertAt = lines.firstIndex(where: { isKeyAssignment($0, key: "workspace") }).map { $0 + 1 }
                ?? linearHeaderIndex + 1
            lines.insert(appUserLine, at: insertAt)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes `[linear].client_id` — the withdrawn client-credentials setup's leftover key
    /// (`ConfigurationError.Reason.legacyLinearClientID`, P17.6) — so a hand-edited or old `config.toml`
    /// can be loaded once, rather than refusing forever. A no-op when the line is already gone.
    public static func removingLegacyLinearClientID(inFileText text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let linearHeaderIndex = lines.firstIndex(where: { isTableHeader($0, named: "linear") }) else {
            return text
        }
        var searchIndex = linearHeaderIndex + 1
        while searchIndex < lines.count, !isAnyTableHeader(lines[searchIndex]) {
            if isKeyAssignment(lines[searchIndex], key: "client_id") {
                lines.remove(at: searchIndex)
                return lines.joined(separator: "\n")
            }
            searchIndex += 1
        }
        return text
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
        ProjectFileDraft(self).renderedTOML
    }
}
