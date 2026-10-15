import Config
import Domain
import Foundation
import Testing

/// A throwaway directory holding sibling Repos, written by hand: no git is run.
private final class ScanWorkspace: @unchecked Sendable {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "repo-dependency-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ name: String) -> String {
        root.appending(path: name, directoryHint: .isDirectory).path(percentEncoded: false)
    }

    /// Writes `files` (relative path → content) into the Repo `name`, and its `.git/config` when `origin` is given.
    @discardableResult
    func repo(
        _ name: String, role: String = "backend", origin: String? = nil, files: [String: String] = [:]
    ) throws -> ScannedRepo {
        var all = files
        if let origin {
            all[".git/config"] = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \(origin)\n\tfetch = +refs/*\n"
        }
        let base = URL(filePath: path(name), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (relative, content) in all {
            let file = base.appending(path: relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        return ScannedRepo(name: name, path: path(name), role: role)
    }
}

private let contractsOrigin = "git@github.com:acme/contracts.git"

/// `app` carrying `files`, next to a `contracts` sibling whose origin is `contractsOrigin`.
private func scan(
    _ workspace: ScanWorkspace, files: [String: String], contractsFiles: [String: String] = [:],
    addedRepos: Set<String>? = nil
) throws -> RepoDependencyScanResult {
    let app = try workspace.repo("app", files: files)
    let contracts = try workspace.repo("contracts", origin: contractsOrigin, files: contractsFiles)
    return RepoDependencyScan.scan(repos: [app, contracts], addedRepos: addedRepos)
}

private func only(_ result: RepoDependencyScanResult) throws -> RepoDependencyProposal {
    #expect(result.proposals.count == 1)
    return try #require(result.proposals.first)
}

@Suite("Repo Dependency scan")
struct RepoDependencyScanTests {
    // MARK: - Package.swift

    @Test("A Package.swift url with from: is a tag edge, matched across https and git@ spellings of the origin")
    func packageURLWithVersion() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["Package.swift": """
            let package = Package(
                dependencies: [
                    .package(
                        url: "https://GitHub.com/acme/contracts.git",
                        from: "1.2.0"
                    )
                ]
            )
            """])

        let proposal = try only(result)
        #expect(proposal.consumer == "app")
        #expect(proposal.producer == "contracts")
        #expect(proposal.via == .tag)
        #expect(proposal.evidenceFile == "Package.swift")
        #expect(
            proposal.evidenceReference == #".package( url: "https://GitHub.com/acme/contracts.git", from: "1.2.0" )"#
        )
    }

    @Test("Other version pins of a Package.swift url are tag edges; a branch is mainline; a revision has no via",
          arguments: [
              (#"exact: "1.0.0""#, RepoDependencyVia.tag),
              (#".upToNextMinor(from: "1.0.0")"#, .tag),
              (#""1.0.0"..<"2.0.0""#, .tag),
              (#"branch: "main""#, .mainline),
              (#".branch("develop")"#, .mainline),
              (#"revision: "abc123""#, nil)
          ] as [(String, RepoDependencyVia?)])
    func packagePins(pin: String, expected: RepoDependencyVia?) throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: [
            "Package.swift": #".package(url: "git@github.com:acme/contracts.git", \#(pin))"#
        ])
        let proposal = try only(result)
        #expect(proposal.via == expected)
    }

    @Test("A Package.swift path: resolving to a sibling is a mainline edge")
    func packagePath() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["Package.swift": #".package(path: "../contracts"),"#])
        let proposal = try only(result)
        #expect(proposal.via == .mainline)
        #expect(proposal.producer == "contracts")
    }

    @Test("A .package call in a comment, or naming no sibling, proposes nothing")
    func packageNoise() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["Package.swift": """
            // .package(path: "../contracts"),
            .package(url: "https://github.com/other/thing.git", from: "1.0.0"),
            .package(path: "../elsewhere"),
            """])
        #expect(result.foundNothing)
    }

    // MARK: - package.json

    @Test("package.json dependencies: paths are mainline, tags pin a release, a commit has no via",
          arguments: [
              (#""contracts-lib": "file:../contracts""#, RepoDependencyVia.mainline),
              (#""contracts-lib": "link:../contracts""#, .mainline),
              (#""contracts-lib": "git+ssh://git@github.com/acme/contracts.git#v1.0.0""#, .tag),
              (#""contracts-lib": "github:acme/contracts#1.4.0""#, .tag),
              (#""contracts-lib": "acme/contracts#semver:^1.0.0""#, .tag),
              (#""contracts-lib": "github:acme/contracts#0123456789abcdef0123456789abcdef01234567""#, nil),
              (#""contracts-lib": "acme/contracts#develop""#, .mainline),
              (#""contracts-lib": "git+https://github.com/acme/contracts.git""#, .mainline)
          ] as [(String, RepoDependencyVia?)])
    func packageJSONReferences(entry: String, expected: RepoDependencyVia?) throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["package.json": #"{ "dependencies": { \#(entry) } }"#])
        let proposal = try only(result)
        #expect(proposal.producer == "contracts")
        #expect(proposal.via == expected)
        #expect(proposal.evidenceFile == "package.json")
    }

    @Test("A registry range matches a sibling only when that sibling's package.json name is the key")
    func packageJSONRegistryRange() throws {
        let workspace = ScanWorkspace()
        let matching = try scan(
            workspace, files: ["package.json": #"{ "devDependencies": { "@acme/contracts": "^1.2.0" } }"#],
            contractsFiles: ["package.json": #"{ "name": "@acme/contracts" }"#]
        )
        let proposal = try only(matching)
        #expect(proposal.via == .tag)

        let other = ScanWorkspace()
        let unrelated = try scan(
            other, files: ["package.json": #"{ "dependencies": { "left-pad": "^1.2.0" } }"#],
            contractsFiles: ["package.json": #"{ "name": "@acme/contracts" }"#]
        )
        #expect(unrelated.foundNothing)
    }

    @Test("An unparsable package.json is named in the skipped files, not thrown")
    func unparsablePackageJSON() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["package.json": "{ not json"])
        #expect(result.foundNothing)
        #expect(result.skippedFiles.map(\.file) == ["app/package.json"])
    }

    // MARK: - .gitmodules

    @Test("A submodule is a commit pin unless it follows a branch")
    func submodules() throws {
        let pinned = ScanWorkspace()
        let result = try scan(pinned, files: [".gitmodules": """
            [submodule "contracts"]
            \tpath = vendor/contracts
            \turl = git@github.com:acme/contracts.git
            """])
        #expect(try only(result).via == nil)
        #expect(try only(result).evidenceFile == ".gitmodules")

        let following = ScanWorkspace()
        let branched = try scan(following, files: [".gitmodules": """
            [submodule "contracts"]
            \turl = https://github.com/acme/contracts
            \tbranch = main
            [submodule "other"]
            \turl = https://github.com/acme/other.git
            """])
        #expect(try only(branched).via == .mainline)
    }

    // MARK: - Generators

    @Test("A generator script line naming a sibling's path is a mainline edge, with its file and line number")
    func generatorLine() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["Makefile": """
            all:
            \tcp ../contracts/schema.json gen/schema.json
            \tcp ../contracts/other.json gen/other.json
            """])

        let proposal = try only(result)
        #expect(proposal.via == .mainline)
        #expect(proposal.evidenceFile == "Makefile:2")
        #expect(proposal.evidenceReference == "cp ../contracts/schema.json gen/schema.json")
    }

    @Test("The sweep reaches two directory levels down and reads absolute and ~ spellings of a path")
    func generatorSweepDepthAndSpellings() throws {
        let workspace = ScanWorkspace()
        let app = try workspace.repo("app", files: [
            "tools/gen/sync.sh": "rsync -a \(workspace.path("contracts"))/ out/",
            "a/b/c/too-deep.sh": "cp ../contracts x"
        ])
        let contracts = try workspace.repo("contracts")
        let result = RepoDependencyScan.scan(repos: [app, contracts])
        let proposal = try only(result)
        #expect(proposal.evidenceFile == "tools/gen/sync.sh:1")
    }

    @Test("A name that merely starts like a sibling's is not a reference to it")
    func generatorRequiresWholePathComponents() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["Makefile": "cp ../contracts-extra/x y\ncp ../mycontracts/x y"])
        #expect(result.foundNothing)
    }

    @Test("A generator file over 1 MB is skipped and named")
    func oversizedGeneratorFile() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: ["big.json": String(repeating: "x", count: 1_100_000)])
        #expect(result.foundNothing)
        #expect(result.skippedFiles.map(\.file) == ["app/big.json"])
    }

    @Test("Directories such as node_modules and .build are not swept")
    func skippedDirectories() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: [
            "node_modules/pkg/Makefile": "cp ../contracts x",
            ".build/Makefile": "cp ../contracts x"
        ])
        #expect(result.foundNothing)
    }

    // MARK: - Spec Repo, matching, filtering

    @Test("The spec Repo is a mainline producer for every other Repo, and consumes nothing itself")
    func specRepo() throws {
        let workspace = ScanWorkspace()
        let spec = try workspace.repo("spec", role: "spec")
        let backend = try workspace.repo("backend")
        let mobile = try workspace.repo("mobile", role: "mobile")

        let result = RepoDependencyScan.scan(repos: [spec, backend, mobile])

        #expect(result.proposals.map { "\($0.consumer)>\($0.producer)" } == ["backend>spec", "mobile>spec"])
        #expect(result.proposals.allSatisfy { $0.via == .mainline && $0.evidenceFile.isEmpty })
        #expect(result.proposals.allSatisfy { $0.evidenceReference == "the Project's specification source" })
    }

    @Test("A URL matching no sibling, and a reference to the consumer itself, propose nothing")
    func nonSiblingsAndSelf() throws {
        let workspace = ScanWorkspace()
        let app = try workspace.repo("app", origin: "git@github.com:acme/app.git", files: [
            "Package.swift": """
                .package(url: "https://github.com/acme/app.git", from: "1.0.0"),
                .package(path: "../app"),
                .package(url: "https://github.com/acme/unknown.git", from: "1.0.0"),
                """
        ])
        let contracts = try workspace.repo("contracts", origin: contractsOrigin)
        #expect(RepoDependencyScan.scan(repos: [app, contracts]).foundNothing)
    }

    @Test("A Repo with none of these files has nothing found")
    func nothingFound() throws {
        let workspace = ScanWorkspace()
        let app = try workspace.repo("app")
        let result = RepoDependencyScan.scan(repos: [app])
        #expect(result.foundNothing)
        #expect(result.skippedFiles.isEmpty)
    }

    @Test("The origin of a linked Worktree is read through its .git file and commondir")
    func worktreeOrigin() throws {
        let workspace = ScanWorkspace()
        let main = try workspace.repo("contracts-main", origin: contractsOrigin)
        let linked = try workspace.repo("contracts", files: [
            ".git": "gitdir: \(main.path)/.git/worktrees/contracts\n"
        ])
        try FileManager.default.createDirectory(
            atPath: main.path + "/.git/worktrees/contracts", withIntermediateDirectories: true
        )
        try "../..\n".write(
            toFile: main.path + "/.git/worktrees/contracts/commondir", atomically: true, encoding: .utf8
        )
        let app = try workspace.repo("app", files: [
            "Package.swift": #".package(url: "https://github.com/acme/contracts", from: "1.0.0")"#
        ])

        let result = RepoDependencyScan.scan(repos: [app, linked])
        #expect(try only(result).producer == "contracts")
    }

    @Test("addedRepos keeps only the proposals touching an added Repo")
    func addedReposFilter() throws {
        let workspace = ScanWorkspace()
        let app = try workspace.repo("app", files: ["Makefile": "cp ../contracts x\ncp ../web x"])
        let contracts = try workspace.repo("contracts", origin: contractsOrigin)
        let web = try workspace.repo("web")
        let all = RepoDependencyScan.scan(repos: [app, contracts, web])
        #expect(all.proposals.map(\.producer) == ["contracts", "web"])

        let added = RepoDependencyScan.scan(repos: [app, contracts, web], addedRepos: ["web"])
        #expect(added.proposals.map(\.producer) == ["web"])
        let consumerAdded = RepoDependencyScan.scan(repos: [app, contracts, web], addedRepos: ["app"])
        #expect(consumerAdded.proposals.count == 2)
        #expect(RepoDependencyScan.scan(repos: [app, contracts, web], addedRepos: []).foundNothing)
    }

    @Test("One proposal per consumer and producer: the first evidence found wins")
    func dedupe() throws {
        let workspace = ScanWorkspace()
        let result = try scan(workspace, files: [
            "Package.swift": #".package(url: "https://github.com/acme/contracts.git", from: "1.0.0")"#,
            "Makefile": "cp ../contracts/x y"
        ])
        let proposal = try only(result)
        #expect(proposal.evidenceFile == "Package.swift")
        #expect(proposal.via == .tag)
    }
}
