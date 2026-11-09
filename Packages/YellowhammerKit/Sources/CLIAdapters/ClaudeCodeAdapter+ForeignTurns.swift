import Domain
import Foundation

extension ClaudeCodeAdapter {
    static let lastMessageIDFileName = ".last-message-id"

    func configDirectory(for dispatch: CLIDispatch) -> URL {
        if let configDirectory {
            return configDirectory
        }
        if let env = dispatch.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(filePath: env, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(component: ".claude", directoryHint: .isDirectory)
    }

    public static func encodeWorktreePath(_ path: String) -> String {
        String(path.map { character in
            (character.isASCII && (character.isLetter || character.isNumber)) ? character : "-"
        })
    }

    func transcriptURL(for sessionID: String, dispatch: CLIDispatch) -> URL? {
        let configDir = configDirectory(for: dispatch)
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
        guard let url = transcriptURL(for: sessionID, dispatch: dispatch),
              let data = try? Data(contentsOf: url) else {
            return
        }
        guard let lastUUID = Self.lastMessageUUID(in: data) else {
            return
        }
        let markerFile = dispatch.runDirectory.appendingPathComponent(Self.lastMessageIDFileName)
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

    public func foreignTurns(before dispatch: CLIDispatch) -> Bool {
        guard let resume = dispatch.resume else { return false }
        guard let url = transcriptURL(for: resume.rawValue, dispatch: dispatch),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        let markerFile = dispatch.runDirectory.appendingPathComponent(Self.lastMessageIDFileName)
        let marker = (try? String(contentsOf: markerFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveMarker = marker?.isEmpty == false ? marker : nil
        return Self.hasForeignTurns(in: data, marker: effectiveMarker)
    }

    static func hasForeignTurns(in data: Data, marker: String?) -> Bool {
        struct TranscriptRecord {
            let type: String
            let uuid: String?
            let entrypoint: String?
        }

        var records: [TranscriptRecord] = []
        for bytes in data.split(separator: 0x0A) {
            guard let line = String(data: Data(bytes), encoding: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }
            records.append(TranscriptRecord(
                type: type,
                uuid: object["uuid"] as? String,
                entrypoint: object["entrypoint"] as? String
            ))
        }

        if records.contains(where: { $0.type == "user" && $0.entrypoint != "sdk-cli" }) {
            return true
        }

        if let marker, let markerIndex = records.firstIndex(where: { $0.uuid == marker }) {
            let recordsAfter = records[(markerIndex + 1)...]
            if recordsAfter.contains(where: { $0.type == "user" || $0.type == "assistant" }) {
                return true
            }
        }

        return false
    }
}
