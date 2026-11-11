import Domain
import Foundation

/// OQ201 observations. Only the disposable Probe's cwd/session is retained; unrelated agents and
/// prompts from the machine-wide `worktree ps` response never leave this adapter.
extension OrcaADEAdapter {
    public func probeTab(
        cli: String, worktree: WorkspaceWorktree, name: String, nonce: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> OrcaProbeFindings {
        var findings = OrcaProbeFindings()
        do {
            let payload: ProbePS = try await perform(["worktree", "ps", "--limit", "10000", "--json"])
            let rows = payload.worktrees.filter {
                $0.worktreeId == worktree.id.rawValue && Self.probePath($0.path) == Self.probePath(worktree.path)
            }
            let agent = rows.flatMap(\.agents).first {
                $0.agentType == Self.probeAgent(cli) && $0.prompt?.contains(nonce) == true
            }
            guard let agent else {
                findings.tabRecognition = .init(
                    payload.truncated == true || rows.isEmpty ? .notRun : .failed,
                    detail: "no matching live \(cli) agent observed in the Probe Worktree"
                )
                return findings
            }
            findings.tabRecognition = .init(
                agent.conversationName == name ? .passed : .failed,
                detail: agent.conversationName == name
                    ? "worktree ps matched the CLI, Probe prompt and conversationName"
                    : "CLI recognised, but conversationName did not match the Probe session name"
            )
            // This is application-level evidence plus the installed transport, not a packet capture.
            // Never read or retain hook tokens, arbitrary tool inputs, or other sessions' prompts.
            let script = homeDirectory.appendingPathComponent(".orca/agent-hooks/\(Self.probeAgent(cli))-hook.sh")
            let transport = (try? String(contentsOf: script, encoding: .utf8))?.contains("http://127.0.0.1:") == true
            if transport, agent.toolInput?.contains("yh-probe-hold.sh tabclose") == true {
                findings.hookTraffic = .init(.passed, detail:
                    "Probe prompt and hold-tool input observed in Orca; the installed hook POSTs its payload "
                    + "to 127.0.0.1. Transport inferred from the hook script; no packet capture."
                )
            } else {
                findings.hookTraffic = .init(.notRun, detail:
                    "prompt/tool-input flow to Orca's 127.0.0.1 hook listener could not be confirmed"
                )
            }
        } catch {
            findings.tabRecognition = .init(.notRun, detail: "Orca agents observation unavailable: \(error)")
        }
        return findings
    }

    /// Search is one way to observe History, not its authority. A disabled/full index or an incomplete
    /// page is unconfirmed, never evidence that the History panel has no session. No setting is changed.
    public func probeHistory(
        cli: String, cwd: String, sessionID: String, name: String, nonce: String
    ) async -> OrcaProbeFindings {
        var findings = OrcaProbeFindings()
        var cursor: String?
        var seenCursors: Set<String> = []
        do {
            repeat {
                var args = ["search", nonce, "--agent", Self.probeAgent(cli), "--path", cwd]
                // macOS temporary directories have /var and /private/var spellings. Search accepts
                // literal paths, so ask for both rather than hiding the same session behind an alias.
                let physicalCwd = Self.probePath(cwd)
                if physicalCwd != cwd { args += ["--path", physicalCwd] }
                args += ["--fresh", "--limit", "100", "--json"]
                if let cursor { args += ["--cursor", cursor] }
                let payload: ProbeHistory = try await perform(args)
                guard payload.kind == "results", let hits = payload.hits else {
                    let why = payload.reason ?? payload.kind
                    findings.sessionHistory = .init(.notRun, detail:
                        "Orca search unavailable (\(why)); the Session History panel was not observed"
                    )
                    return findings
                }
                if let hit = hits.first(where: {
                    $0.agent == Self.probeAgent(cli) && $0.cwd.map(Self.probePath) == physicalCwd
                        && $0.sessionId == sessionID
                        && $0.source?.presence == "present"
                }) {
                    findings.sessionHistory = .init(.passed, detail: "Orca indexed the direct session at its exact cwd")
                    findings.sessionName = .init(
                        hit.title == name ? .passed : .failed,
                        detail: hit.title == name ? "History title matches the direct pass's session name"
                            : "History title does not match the requested session name; known behaviour retained"
                    )
                    return findings
                }
                if payload.truncated?.isIncomplete == true {
                    findings.sessionHistory = .init(.notRun, detail: "Orca search was incomplete; History unconfirmed")
                    return findings
                }
                cursor = payload.page?.hasMore == true ? payload.page?.cursor : nil
                if payload.page?.hasMore == true, cursor == nil || !seenCursors.insert(cursor ?? "").inserted {
                    findings.sessionHistory = .init(.notRun, detail: "Orca search did not provide a usable next page")
                    return findings
                }
            } while cursor != nil && !Task.isCancelled
            findings.sessionHistory = .init(.notRun, detail:
                "the direct session was not observed in Orca search; this does not establish absence from History"
            )
        } catch {
            findings.sessionHistory = .init(.notRun, detail: "Orca history observation unavailable: \(error)")
        }
        return findings
    }

    private static func probeAgent(_ cli: String) -> String { cli == "agy" ? "antigravity" : cli }
    private static func probePath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct ProbePS: Decodable {
    struct Worktree: Decodable {
        let worktreeId: String
        let path: String
        let agents: [ProbePSAgent]
    }
    let worktrees: [Worktree]
    let truncated: Bool?
}

private struct ProbeHistory: Decodable {
    struct Hit: Decodable {
        let agent: String
        let sessionId: String
        let title: String
        let cwd: String?
        let source: ProbeHistorySource?
    }
    struct Page: Decodable { let cursor: String?; let hasMore: Bool }
    struct Truncation: Decodable {
        let candidates: Bool
        let query: Bool
        let freshness: Bool
        var isIncomplete: Bool { candidates || query || freshness }
    }
    let kind: String
    let reason: String?
    let hits: [Hit]?
    let page: Page?
    let truncated: Truncation?
}

private struct ProbePSAgent: Decodable {
    let agentType: String?
    let conversationName: String?
    let prompt: String?
    let toolInput: String?
}

private struct ProbeHistorySource: Decodable { let presence: String }
