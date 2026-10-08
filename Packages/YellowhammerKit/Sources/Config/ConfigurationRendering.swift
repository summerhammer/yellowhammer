import Domain
import Foundation

// swiftlint:disable file_length

/// Renders configuration values back to the TOML shapes ``ConfigurationDecoding`` accepts, for setup to
/// write `~/.config/yellowhammer/config.toml` and `projects/<id>.toml` with the spec's defaults spelled
/// out (bounds/bound-unanswered-nights: "Initial setup sets `overdue_nights_max = 3` in each
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

    /// `[board.linear.connections.<name>]`, the name bare when it can be and quoted otherwise.
    static func installationHeader(_ name: String) -> String {
        "[board.linear.connections.\(TOMLKey.isBare(name) ? name : quotedKey(name))]"
    }

    /// `[code_hosting.github.connections.<name>]`, the name bare when it can be and quoted otherwise.
    static func codeHostingConnectionHeader(_ name: String) -> String {
        "[code_hosting.github.connections.\(TOMLKey.isBare(name) ? name : quotedKey(name))]"
    }

    /// One Code Hosting Connection: its `type`, and for a Keychain token its `credential`.
    static func renderedCodeHostingConnection(_ connection: CodeHostingConnection) -> String {
        var lines = [codeHostingConnectionHeader(connection.name)]
        switch connection.kind {
        case .githubCLI(let executable):
            lines.append("type = \"gh\"")
            if let executable {
                lines.append("executable = \(quoted(executable))")
            }
        case .keychainToken(let credential):
            lines.append("type = \"keychain\"")
            lines.append("credential = \(quoted(credential.rawValue))")
        }
        return lines.joined(separator: "\n")
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

    /// `work_kind = "…"`, omitted when `work_kind` is `""` (not set — the loader treats that as `*`).
    static func kindLine(_ kind: String) -> String? {
        kind.isEmpty ? nil : "work_kind = \(quoted(kind))"
    }

    /// `repo_role = "…"`, omitted when `repoRole` is `""` (not set — the loader treats that as any Repo Role).
    static func repoRoleLine(_ repoRole: String) -> String? {
        repoRole.isEmpty ? nil : "repo_role = \(quoted(repoRole))"
    }

    /// One `[[routing]]` entry, in the key order the decoder reads: `work_kind`, `repo_role`, `route`,
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

    /// `<key> = "…"` for a Message Template, omitted when it is its Kind's built-in default.
    static func templateLine(_ template: MessageTemplate) -> String? {
        guard template.text != template.kind.defaultText else { return nil }
        return "\(template.kind.key) = \(quoted(template.text))"
    }

    /// All six Bounds, explicit — see the spec citation on ``ConfigurationRendering``.
    static func renderedLimits(_ bounds: BoundsDraft) -> String {
        """
        [limits]
        review_rounds_max = \(boundValue(bounds.reviewRoundsMax))
        attempts_per_work_card = \(boundValue(bounds.attemptsPerWorkCard))
        overdue_nights_max = \(boundValue(bounds.unansweredNightsMax))
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
    /// Renders one `[board.linear.connections.<name>]` table per Board Connection, one
    /// `[code_hosting.github.connections.<name>]` table per Code Hosting Connection, one `[cli.<name>]` table
    /// per declared adapter and the base Routing Table, in the shape ``MachineConfigurationDecoder`` reads back.
    public var renderedTOML: String {
        renderedTOML(routingTable: routingTable.map(RoutingEntryDraft.init))
    }

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line,
    /// including comments. Replaces the `operator` line inside `[board.linear.connections.<name>]`, or
    /// inserts one after that table's last key when absent. Returns `text` unchanged when no such table
    /// header exists. Applying it twice equals applying it once.
    public static func settingOperator(
        _ operatorIdentity: BoardObjectID, installation name: String, inFileText text: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = installationHeaderIndex(named: name, in: lines) else { return text }
        setKey("operator", to: operatorIdentity.rawValue, tableAt: header, in: &lines)
        return lines.joined(separator: "\n")
    }

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line,
    /// including comments. Removes the `[board.linear.connections.<name>]` header and every line after
    /// it up to, not including, the next table header (or the end of the file), except that a comment block
    /// directly above the next header stays with that table. No gap is doubled. Returns `text`
    /// unchanged when no such table header exists. Applying it twice equals applying it once.
    public static func removingLinearInstallation(named name: String, inFileText text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = installationHeaderIndex(named: name, in: lines) else { return text }
        var end = header + 1
        while end < lines.count, !isAnyTableHeader(lines[end]) { end += 1 }
        // A comment block right above the next header belongs to that next table: keep it.
        var removeEnd = end
        if end < lines.count {
            while removeEnd > header + 1 {
                let trimmed = lines[removeEnd - 1].trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
                removeEnd -= 1
            }
        }
        lines.removeSubrange(header..<removeEnd)
        // Do not leave a doubled gap where the removed table sat.
        while header > 0, header < lines.count,
              lines[header - 1].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[header].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: header)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the named Code Hosting Connection table, preserving comments attached to the next table.
    public static func removingCodeHostingConnection(named name: String, inFileText text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = codeHostingHeaderIndex(named: name, in: lines) else { return text }
        var end = header + 1
        while end < lines.count, !isAnyTableHeader(lines[end]) { end += 1 }
        var removeEnd = end
        if end < lines.count {
            while removeEnd > header + 1 {
                let trimmed = lines[removeEnd - 1].trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
                removeEnd -= 1
            }
        }
        lines.removeSubrange(header..<removeEnd)
        while header > 0, header < lines.count,
              lines[header - 1].trimmingCharacters(in: .whitespaces).isEmpty,
              lines[header].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: header)
        }
        return lines.joined(separator: "\n")
    }

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line,
    /// including comments. Adds or replaces the entry called `installation.name`. When its table exists,
    /// `credential`, `workspace` and `yellowhammer_identity` are set in place (inserted when missing) and `operator`
    /// is written only when the installation has one, so a re-connect keeps the Operator identity. When it
    /// does not, a new table is appended at the end of the file. Applying it twice equals applying it once.
    public static func settingLinearInstallation(
        _ installation: LinearInstallation, inFileText text: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = installationHeaderIndex(named: installation.name, in: lines) else {
            var result = text
            if !result.isEmpty {
                if !result.hasSuffix("\n") { result += "\n" }
                result += "\n"
            }
            var table = [
                ConfigurationRendering.installationHeader(installation.name),
                "credential = \(ConfigurationRendering.quoted(installation.credential.rawValue))",
                "workspace = \(ConfigurationRendering.quoted(installation.workspace.rawValue))",
                "yellowhammer_identity = \(ConfigurationRendering.quoted(installation.appUser.rawValue))"
            ]
            if let operatorIdentity = installation.operatorIdentity {
                table.append("operator = \(ConfigurationRendering.quoted(operatorIdentity.rawValue))")
            }
            return result + table.joined(separator: "\n") + "\n"
        }
        setKey("credential", to: installation.credential.rawValue, tableAt: header, in: &lines)
        setKey("workspace", to: installation.workspace.rawValue, tableAt: header, in: &lines)
        setKey("yellowhammer_identity", to: installation.appUser.rawValue, tableAt: header, in: &lines)
        if let operatorIdentity = installation.operatorIdentity {
            setKey("operator", to: operatorIdentity.rawValue, tableAt: header, in: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// A textual edit of an existing, hand-maintained `config.toml`: preserves every other line, including
    /// comments. Adds or replaces the entry called `connection.name`. When its table exists, `type` is set in
    /// place and `credential` is set (inserted when missing) for a Keychain token, or removed for a `gh` CLI
    /// connection, which holds no token. `executable` is set for a `gh` entry that declares one and removed
    /// otherwise (always removed for a Keychain token). When it does not, a new table is appended at the end of the file.
    /// Applying it twice equals applying it once.
    public static func settingCodeHostingConnection(
        _ connection: CodeHostingConnection, inFileText text: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = codeHostingHeaderIndex(named: connection.name, in: lines) else {
            var result = text
            if !result.isEmpty {
                if !result.hasSuffix("\n") { result += "\n" }
                result += "\n"
            }
            return result + ConfigurationRendering.renderedCodeHostingConnection(connection) + "\n"
        }
        switch connection.kind {
        case .githubCLI(let executable):
            setKey("type", to: "gh", tableAt: header, in: &lines)
            removeKey("credential", tableAt: header, in: &lines)
            if let executable {
                setKey("executable", to: executable, tableAt: header, in: &lines)
            } else {
                removeKey("executable", tableAt: header, in: &lines)
            }
        case .keychainToken(let credential):
            setKey("type", to: "keychain", tableAt: header, in: &lines)
            removeKey("executable", tableAt: header, in: &lines)
            setKey("credential", to: credential.rawValue, tableAt: header, in: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Removes the `key` line from the table whose header is at `header`, when it has one.
    private static func removeKey(_ key: String, tableAt header: Int, in lines: inout [String]) {
        var end = header + 1
        while end < lines.count, !isAnyTableHeader(lines[end]) {
            if isKeyAssignment(lines[end], key: key) {
                lines.remove(at: end)
                return
            }
            end += 1
        }
    }

    /// Sets `key = "value"` in the table whose header is at `header`: replaces the key's line, or inserts
    /// it after the table's last key line (right after the header when it has none).
    fileprivate static func setKey(_ key: String, to value: String, tableAt header: Int, in lines: inout [String]) {
        let newLine = "\(key) = \(ConfigurationRendering.quoted(value))"
        var end = header + 1
        var lastKey = header
        while end < lines.count, !isAnyTableHeader(lines[end]) {
            if isKeyAssignment(lines[end], key: key) {
                lines[end] = newLine
                return
            }
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.contains("=") { lastKey = end }
            end += 1
        }
        lines.insert(newLine, at: lastKey + 1)
    }

    private static func installationHeaderIndex(named name: String, in lines: [String]) -> Int? {
        lines.firstIndex { installationName(ofHeaderLine: $0) == name }
    }

    private static func codeHostingHeaderIndex(named name: String, in lines: [String]) -> Int? {
        lines.firstIndex { codeHostingConnectionName(ofHeaderLine: $0) == name }
    }

    /// The `<name>` of a `[board.linear.connections.<name>]` header line, nil for any other line. The
    /// name may be bare or basic-quoted; whitespace around the dots and brackets and a trailing `#`
    /// comment are allowed.
    private static func installationName(ofHeaderLine line: String) -> String? {
        tableName(ofHeaderLine: line, under: ["board", "linear", "connections"])
    }

    /// The `<name>` of a `[code_hosting.github.connections.<name>]` header line, nil for any other line.
    private static func codeHostingConnectionName(ofHeaderLine line: String) -> String? {
        tableName(ofHeaderLine: line, under: ["code_hosting", "github", "connections"])
    }

    /// The last segment of a `[<prefix>.<name>]` header line, nil for any other line.
    private static func tableName(ofHeaderLine line: String, under prefix: [String]) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return nil }
        let characters = Array(trimmed.dropFirst())
        var index = 0
        var segments: [String] = []
        while true {
            skipSpaces(characters, &index)
            guard let segment = keySegment(characters, &index) else { return nil }
            segments.append(segment)
            skipSpaces(characters, &index)
            guard index < characters.count else { return nil }
            index += 1
            if characters[index - 1] == "]" { break }
            guard characters[index - 1] == "." else { return nil }
        }
        skipSpaces(characters, &index)
        guard index == characters.count || characters[index] == "#" else { return nil }
        guard segments.count == prefix.count + 1, Array(segments.prefix(prefix.count)) == prefix else { return nil }
        return segments[prefix.count]
    }

    fileprivate static func skipSpaces(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
    }

    /// One bare or basic-quoted (`\"` and `\\` escapes) key segment at `index`.
    fileprivate static func keySegment(_ characters: [Character], _ index: inout Int) -> String? {
        var segment = ""
        guard index < characters.count else { return nil }
        if characters[index] == "\"" {
            index += 1
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "\"" { return segment }
                if character == "\\", index < characters.count {
                    segment.append(characters[index])
                    index += 1
                } else {
                    segment.append(character)
                }
            }
            return nil
        }
        while index < characters.count, characters[index].unicodeScalars.allSatisfy(TOMLKey.isBareScalar) {
            segment.append(characters[index])
            index += 1
        }
        return segment.isEmpty ? nil : segment
    }

    private static func isAnyTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }

    fileprivate static func isKeyAssignment(_ line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equalsIndex = trimmed.firstIndex(of: "=") else { return false }
        let lhs = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
        return lhs == key
    }
}

extension ProjectConfiguration {
    /// Renders the Project's identity, Board and Code Hosting selections, Repos, `[limits]` (all six Bounds,
    /// explicit) and `[schedule]` (all three keys, explicit) — see the spec citation on
    /// ``ConfigurationRendering`` — plus a `[github]` title when it is not the default and any Routing Table
    /// overrides.
    public var renderedTOML: String {
        ProjectFileDraft(self).renderedTOML
    }

    /// A textual edit of an existing Project file: preserves every other line, including comments.
    /// Sets `[code_hosting] connection` to `connectionName`. When the table exists, `connection` is set in
    /// place. When an inline `code_hosting = { ... }` table exists, it is replaced in place. When neither exists,
    /// a new `[code_hosting]` table is appended at the end of the file.
    public static func settingCodeHostingConnection(
        named connectionName: String, inFileText text: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { isCodeHostingHeader($0) }) {
            MachineConfiguration.setKey("connection", to: connectionName, tableAt: header, in: &lines)
            return lines.joined(separator: "\n")
        }
        if let inlineIndex = lines.firstIndex(where: {
            MachineConfiguration.isKeyAssignment($0, key: "code_hosting")
        }) {
            let indent = lines[inlineIndex].prefix(while: { $0 == " " || $0 == "\t" })
            let quoted = ConfigurationRendering.quoted(connectionName)
            lines[inlineIndex] = "\(indent)code_hosting = { connection = \(quoted) }"
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            result += "\n"
        }
        return result + "[code_hosting]\nconnection = \(ConfigurationRendering.quoted(connectionName))\n"
    }

    private static func isCodeHostingHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return false }
        let characters = Array(trimmed.dropFirst())
        var index = 0
        var segments: [String] = []
        while true {
            MachineConfiguration.skipSpaces(characters, &index)
            guard let segment = MachineConfiguration.keySegment(characters, &index) else { return false }
            segments.append(segment)
            MachineConfiguration.skipSpaces(characters, &index)
            guard index < characters.count else { return false }
            index += 1
            if characters[index - 1] == "]" { break }
            guard characters[index - 1] == "." else { return false }
        }
        MachineConfiguration.skipSpaces(characters, &index)
        guard index == characters.count || characters[index] == "#" else { return false }
        return segments == ["code_hosting"]
    }
}
