import Domain
import Foundation

extension ClaudeCodeAdapter {
    static let lastMessageIDFileName = ".last-message-id"

    /// The transcript root the spawned `claude` uses: the injected directory, else the dispatch environment's
    /// `CLAUDE_CONFIG_DIR`, else its `$HOME/.claude`. It is read from the dispatch, never from this process's
    /// home: the child is spawned with exactly `dispatch.environment`, so that is where it writes, and a
    /// dispatch with neither variable (every test fixture's empty environment) has no root, so nothing reads
    /// the real `~/.claude`. No root means no transcript: no marker is recorded and the check reports could not check.
    ///
    /// For a tab pass, the CLI runs in an Orca terminal tab inheriting the tab's default environment
    /// (the user's HOME and CLAUDE_CONFIG_DIR if set). In dispatch, CLIDispatch.environment inherits
    /// ProcessInfo.processInfo.environment (also holding HOME and CLAUDE_CONFIG_DIR if set).
    /// Therefore, both the spawned tab CLI and foreignTurns resolve to the same transcript root.
    func configDirectory(for dispatch: CLIDispatch) -> URL? {
        if let configDirectory {
            return configDirectory
        }
        if let env = dispatch.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(filePath: env, directoryHint: .isDirectory)
        }
        if let home = dispatch.environment["HOME"], !home.isEmpty {
            return URL(filePath: home, directoryHint: .isDirectory)
                .appending(component: ".claude", directoryHint: .isDirectory)
        }
        return nil
    }

    public static func encodeWorktreePath(_ path: String) -> String {
        String(path.map { character in
            (character.isASCII && (character.isLetter || character.isNumber)) ? character : "-"
        })
    }

    func transcriptURL(for sessionID: String, dispatch: CLIDispatch) -> URL? {
        guard let configDir = configDirectory(for: dispatch) else { return nil }
        let projectsDir = configDir.appending(component: "projects", directoryHint: .isDirectory)
        let encodedCwd = Self.encodeWorktreePath(dispatch.worktreePath)
        let expectedFile = projectsDir
            .appending(component: encodedCwd, directoryHint: .isDirectory)
            .appending(component: "\(sessionID).jsonl")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: expectedFile.path(percentEncoded: false)) {
            return expectedFile
        }
        guard let subdirs = try? fileManager.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for subdir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let candidate = subdir.appending(component: "\(sessionID).jsonl")
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    func recordLastMessageID(for sessionID: String, dispatch: CLIDispatch) {
        let markerFile = dispatch.runDirectory.appendingPathComponent(Self.lastMessageIDFileName)
        // A failed read must not leave a previous pass's marker looking current.
        try? FileManager.default.removeItem(at: markerFile)
        guard let url = transcriptURL(for: sessionID, dispatch: dispatch),
              let data = try? Data(contentsOf: url) else {
            return
        }
        guard let lastUUID = Self.lastMessageUUID(in: data) else {
            return
        }
        try? lastUUID.write(to: markerFile, atomically: true, encoding: .utf8)
    }

    static func lastMessageUUID(in data: Data) -> String? {
        var lastUUID: String?
        for bytes in data.split(separator: 0x0A) {
            guard let line = String(data: Data(bytes), encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            guard let type = object["type"] as? String, type == "user" || type == "assistant" else {
                continue
            }
            if let uuid = object["uuid"] as? String {
                lastUUID = uuid
            }
        }
        return lastUUID
    }

    public func foreignTurns(before dispatch: CLIDispatch) -> SessionForeignTurnsCheck {
        guard let resume = dispatch.resume else { return .unsupported }
        guard let url = transcriptURL(for: resume.rawValue, dispatch: dispatch),
              let data = try? Data(contentsOf: url) else {
            return .couldNotCheck(reason: "session transcript is missing or unreadable")
        }
        let markerFile = dispatch.runDirectory.appendingPathComponent(Self.lastMessageIDFileName)
        let marker = (try? String(contentsOf: markerFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.checkForeignTurns(in: data, marker: marker?.isEmpty == false ? marker : nil)
    }

    static func checkForeignTurns(in data: Data, marker: String?) -> SessionForeignTurnsCheck {
        struct TranscriptRecord {
            let type: String
            let uuid: String?
            let entrypoint: String?
            let timestamp: String?
        }
        var records: [TranscriptRecord] = []
        var malformed = false
        for bytes in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let type = object["type"] as? String else {
                malformed = true
                continue
            }
            // Restore metadata is not a message, even if it happens to carry a uuid.
            guard type == "user" || type == "assistant" else { continue }
            records.append(TranscriptRecord(
                type: type, uuid: object["uuid"] as? String,
                entrypoint: object["entrypoint"] as? String, timestamp: object["timestamp"] as? String
            ))
        }
        let markerIndex = marker.flatMap { marker in records.lastIndex(where: { $0.uuid == marker }) }
        let foreign = records.enumerated().filter { index, record in
            (record.type == "user" && record.entrypoint != "sdk-cli")
                || markerIndex.map { index > $0 } == true
        }.map(\.element)
        if !foreign.isEmpty {
            return .foreignTurns(
                userCount: foreign.filter { $0.type == "user" }.count,
                assistantCount: foreign.filter { $0.type == "assistant" }.count,
                firstTimestamp: foreign.first?.timestamp
            )
        }
        guard !malformed, !records.isEmpty else {
            return .couldNotCheck(reason: "session transcript contains no messages or has malformed records")
        }
        guard markerIndex != nil else {
            return .couldNotCheck(reason: "last recorded message is missing from the session transcript")
        }
        return .clean
    }
}
