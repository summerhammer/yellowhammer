import Foundation

/// The one JSON envelope every `orca --json` command prints on stdout, success or failure. Unknown
/// keys (such as `_meta`) are tolerated by ordinary `Decodable` synthesis.
struct OrcaEnvelope<Result: Decodable>: Decodable {
    let id: String?
    let ok: Bool
    let result: Result?
    let error: OrcaErrorPayload?
}

struct OrcaErrorPayload: Decodable {
    let code: String
    let message: String
}

/// One Worktree as `orca` reports it, whether from `create`, `list` or embedded in another result.
struct OrcaWorktreePayload: Decodable {
    let id: String
    let path: String
    let branch: String
    let displayName: String
    let head: String?
    let isMainWorktree: Bool?
    let baseRef: String?
}

struct OrcaCreateResultPayload: Decodable {
    let worktree: OrcaWorktreePayload?
}

struct OrcaListResultPayload: Decodable {
    let worktrees: [OrcaWorktreePayload]?
}

struct OrcaRemoveResultPayload: Decodable {
    let removed: Bool?
}

struct OrcaRepositoryPayload: Decodable {
    let path: String
}

struct OrcaRepositoriesPayload: Decodable {
    let repos: [OrcaRepositoryPayload]
}

/// Registration's result carries vendor metadata that the caller does not need.
struct OrcaRepositoryResultPayload: Decodable {
    let repo: OrcaRepositoryPayload
}
