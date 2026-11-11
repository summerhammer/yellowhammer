import Domain
import Foundation

extension ClaudeCodeAdapter {
    public func probeForeignTurnMarker(of session: CLISession, dispatch: CLIDispatch) -> ProbeObservation {
        guard let url = transcriptURL(for: session.rawValue, dispatch: dispatch),
              let data = try? Data(contentsOf: url) else {
            return .init(.notRun, detail: "Claude transcript unavailable; entrypoint unconfirmed")
        }
        return Self.probeEntrypoint(in: data)
    }

    static func probeEntrypoint(in data: Data) -> ProbeObservation {
        let records = probeJSONLines(data)
        let users = records.filter { $0["type"] as? String == "user" }
        guard !users.isEmpty else { return .init(.notRun, detail: "no Claude user record observed") }
        let found = users.contains { $0["entrypoint"] as? String == "sdk-cli" }
        return .init(found ? .passed : .failed, detail: found
            ? "Claude user entrypoint=sdk-cli observed (interactive counterpart: cli)"
            : "Claude user records did not carry entrypoint=sdk-cli; known behaviour retained")
    }
}

extension CodexAdapter {
    public func probeForeignTurnMarker(of session: CLISession, dispatch: CLIDispatch) -> ProbeObservation {
        let root: URL
        if let configured = dispatch.environment["CODEX_HOME"], !configured.isEmpty {
            root = URL(filePath: configured)
        } else if let home = dispatch.environment["HOME"], !home.isEmpty {
            root = URL(filePath: home).appendingPathComponent(".codex")
        } else {
            return .init(.notRun, detail: "Codex transcript root unavailable")
        }
        // Read only a matching rollout under Codex's documented sessions root, never arbitrary files
        // found in a Worktree, and validate its session id and cwd before trusting metadata.
        let sessions = root.appendingPathComponent("sessions")
        let files = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasSuffix("-\(session.rawValue).jsonl"),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? handle.read(upToCount: 64 * 1024)
            try? handle.close()
            guard let data else { continue }
            return Self.probeSource(in: data, sessionID: session.rawValue, cwd: dispatch.worktreePath)
        }
        return .init(.notRun, detail: "Codex rollout unavailable; origin marker unconfirmed, known behaviour retained")
    }

    static func probeSource(in data: Data, sessionID: String, cwd: String) -> ProbeObservation {
        guard let record = probeJSONLines(data).first(where: { $0["type"] as? String == "session_meta" }),
              let meta = record["payload"] as? [String: Any],
              meta["id"] as? String == sessionID, let recordedCwd = meta["cwd"] as? String,
              URL(filePath: recordedCwd).resolvingSymlinksInPath().standardizedFileURL
                == URL(filePath: cwd).resolvingSymlinksInPath().standardizedFileURL else {
            return .init(.notRun, detail: "no Codex session_meta matching the Probe session and cwd")
        }
        guard let source = meta["source"] as? String else {
            return .init(.notRun, detail: "Codex session_meta has no string source marker; known behaviour retained")
        }
        return .init(source == "exec" ? .passed : .failed, detail:
            source == "exec"
                ? "Codex session_meta.source=exec observed; resume foreign-turn checking remains unsupported"
                : "Codex headless source was not exec; known behaviour retained"
        )
    }
}

private func probeJSONLines(_ data: Data) -> [[String: Any]] {
    data.split(separator: 0x0A).compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
    }
}
