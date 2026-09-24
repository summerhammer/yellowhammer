import Config
import Domain
import Foundation

extension Doctor {
    /// Check 3: `git --version` at least 2.38 (CLAUDE.md), once; then, for every valid Project, each
    /// Repo's `path` and its `specSource` (when present), `~`-expanded against the injected home
    /// directory, must exist and be a git work tree.
    func runGitCheck(configuration: Configuration) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = [await runGitVersionCheck()]
        for project in configuration.projects {
            for repo in project.repos {
                findings.append(await checkWorkTree(
                    path: repo.path, subject: "Project \(project.id.rawValue) repo \(repo.name)", project: project.id
                ))
            }
            if let specSource = project.specSource {
                findings.append(await checkWorkTree(
                    path: specSource, subject: "Project \(project.id.rawValue) spec source", project: project.id
                ))
            }
        }
        return findings
    }

    private func runGitVersionCheck() async -> DoctorFinding {
        let result = await git.run(["--version"])
        guard result.isSuccess, let version = GitVersion.parse(result.stdout) else {
            return finding(.git, subject: "git", .failure, "could not determine the git version from `git --version`")
        }
        guard version.meets(minimumMajor: 2, minimumMinor: 38) else {
            return finding(
                .git, subject: "git", .failure,
                "git \(version.description) is older than the required 2.38" // glossary:ignore GL001
            )
        }
        return finding(.git, subject: "git", .pass, "git \(version.description) meets the required 2.38")
    }

    private func checkWorkTree(path: String, subject: String, project: ProjectID) async -> DoctorFinding {
        let expanded = Doctor.expandTilde(path, homeDirectory: homeDirectory.path(percentEncoded: false))
        guard FileManager.default.fileExists(atPath: expanded) else {
            return finding(
                .git, subject: subject, .failure, "\(subject) at \(expanded) does not exist", project: project
            )
        }
        let result = await git.run(["-C", expanded, "rev-parse", "--is-inside-work-tree"])
        guard result.isSuccess, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return finding(
                .git, subject: subject, .failure, "\(subject) at \(expanded) is not a git repository", project: project
            )
        }
        return finding(.git, subject: subject, .pass, "\(subject) at \(expanded) is a git repository", project: project)
    }

    /// Expands a leading `~` against `homeDirectory`, never the real one. `~foo` (a named user) is
    /// left untouched: doctor never resolves another account's home.
    static func expandTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + path.dropFirst(1)
        }
        return path
    }
}

/// A parsed `git --version` version number, and whether it meets a minimum.
struct GitVersion: Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    func meets(minimumMajor: Int, minimumMinor: Int) -> Bool {
        (major, minor) >= (minimumMajor, minimumMinor)
    }

    /// Parses `"git version 2.39.5 (Apple Git-154)"` into `(2, 39, 5)`. Requires the literal
    /// `"git version "` prefix followed by at least a `major.minor` dotted number; anything else
    /// (including a version with fewer than two components) fails to parse.
    static func parse(_ output: String) -> GitVersion? {
        let prefix = "git version "
        guard let range = output.range(of: prefix) else { return nil }
        let rest = output[range.upperBound...]
        let token = rest.prefix { $0.isNumber || $0 == "." }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return GitVersion(major: major, minor: minor, patch: patch)
    }
}

extension GitVersion: CustomStringConvertible {
    var description: String { "\(major).\(minor).\(patch)" }
}
