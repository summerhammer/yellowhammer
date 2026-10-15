import Domain
import Foundation

/// One Repo as the scan sees it: a configured Repo of the Project being set up.
public struct ScannedRepo: Equatable, Sendable {
    public let name: String
    /// As written; a leading `~` is expanded.
    public let path: String
    /// The Repo Role's raw value; `"spec"` marks the specification Repo.
    public let role: String

    public init(name: String, path: String, role: String) {
        self.name = name
        self.path = path
        self.role = role
    }
}

/// A proposed Repo Dependency and why: the file (relative to the consumer's root) and the reference that
/// produced it.
public struct RepoDependencyProposal: Equatable, Sendable {
    public let consumer: String
    public let producer: String
    /// The `via` guess; nil for a commit pin, where the Operator must choose before the edge can be written.
    public let via: RepoDependencyVia?
    /// The file the reference was found in, relative to the consumer's root; for a line found by the sweep of
    /// generator scripts and configuration, `<file>:<line number>`; empty for the specification Repo's proposals.
    public let evidenceFile: String
    /// The reference as written: the `.package(...)` call, the dependency entry, the submodule's `url`, or the
    /// trimmed line.
    public let evidenceReference: String

    public init(
        consumer: String, producer: String, via: RepoDependencyVia?, evidenceFile: String, evidenceReference: String
    ) {
        self.consumer = consumer
        self.producer = producer
        self.via = via
        self.evidenceFile = evidenceFile
        self.evidenceReference = evidenceReference
    }
}

/// A file the scan could not read or parse. Named, never a failure.
public struct SkippedFile: Equatable, Sendable {
    /// `<repo name>/<relative file>`.
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

public struct RepoDependencyScanResult: Equatable, Sendable {
    public let proposals: [RepoDependencyProposal]
    /// Files the scan could not read or parse, named, never a failure.
    public let skippedFiles: [SkippedFile]

    public var foundNothing: Bool { proposals.isEmpty }

    public init(proposals: [RepoDependencyProposal], skippedFiles: [SkippedFile]) {
        self.proposals = proposals
        self.skippedFiles = skippedFiles
    }
}

/// Proposes Repo Dependencies for a Project's Repos at setup (app/propose-repository-dependencies-at-setup) by
/// reading what each Repo already says about its siblings. The references it knows are examples, not a contract:
/// a kind of reference it does not know proposes nothing. Pure and read-only: it runs no git and writes nothing.
public enum RepoDependencyScan {
    /// `addedRepos` non-nil keeps only proposals with one of those Repos at either end (the add-a-Repo trigger).
    public static func scan(repos: [ScannedRepo], addedRepos: Set<String>? = nil) -> RepoDependencyScanResult {
        let siblings = repos.map(Sibling.init)
        var proposals: [RepoDependencyProposal] = []
        var skipped: [SkippedFile] = []
        for repo in repos {
            var sink = Sink()
            let context = Context(
                consumer: repo, root: standardised(repo.path, relativeTo: nil),
                siblings: siblings.filter { $0.name != repo.name }
            )
            scanPackageSwift(context, into: &sink)
            scanPackageJSON(context, into: &sink)
            scanSubmodules(context, into: &sink)
            scanGenerators(context, into: &sink)
            scanSpecificationRepo(context, repos: repos, into: &sink)
            proposals += unique(sink.findings, consumer: repo.name)
            skipped += sink.skipped
        }
        if let addedRepos {
            proposals = proposals.filter { addedRepos.contains($0.consumer) || addedRepos.contains($0.producer) }
        }
        return RepoDependencyScanResult(proposals: proposals, skippedFiles: skipped)
    }

    /// One proposal per producer, the first evidence found winning.
    private static func unique(_ findings: [Finding], consumer: String) -> [RepoDependencyProposal] {
        var seen: Set<String> = []
        return findings.filter { seen.insert($0.producer).inserted }.map {
            RepoDependencyProposal(
                consumer: consumer, producer: $0.producer, via: $0.via,
                evidenceFile: $0.file, evidenceReference: $0.reference
            )
        }
    }

    /// The specification Repo is read by every other Repo: each proposes it as a producer, via mainline.
    private static func scanSpecificationRepo(_ context: Context, repos: [ScannedRepo], into sink: inout Sink) {
        guard context.consumer.role != "spec" else { return }
        for spec in repos where spec.role == "spec" && spec.name != context.consumer.name {
            sink.findings.append(Finding(
                producer: spec.name, via: .mainline, file: "",
                reference: "the Project's specification source"
            ))
        }
    }
}
