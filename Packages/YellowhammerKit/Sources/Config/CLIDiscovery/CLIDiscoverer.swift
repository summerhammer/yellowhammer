import Domain
import Foundation

/// One file that could be an agent CLI.
public struct CLICandidate: Equatable, Sendable {
    /// The path as found: what gets persisted, since a resolved path vanishes when the CLI updates.
    public let path: String
    /// `path` with symlinks resolved, for de-duplication and display.
    public let resolvedPath: String
    public let source: ExecutableSearchPath.Source
    /// Why the descriptor says this file is not the CLI; a refused candidate is not selectable.
    public let refusal: String?
    /// The program a `#!/usr/bin/env <program>` script looks up on `PATH` (`node` for an npm-installed CLI);
    /// nil for a binary or a script naming its interpreter directly.
    public let envProgram: String?

    public init(
        path: String, resolvedPath: String, source: ExecutableSearchPath.Source, refusal: String?,
        envProgram: String? = nil
    ) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.source = source
        self.refusal = refusal
        self.envProgram = envProgram
    }

    /// A warning that does not rule the file out: an env-interpreted script finds its program only on the
    /// `PATH` it is started with.
    public var caveat: String? {
        guard let envProgram else { return nil }
        return "\(path) is a script run through `env \(envProgram)`; a scheduled run finds \(envProgram) only if "
            + "it is on the PATH yh is scheduled with."
    }
}

/// What discovery found for one descriptor.
public struct CLIDiscovery: Sendable {
    public let descriptor: AgentCLIDescriptor
    /// In search order, refused candidates included so the Operator can be told why.
    public let candidates: [CLICandidate]

    public init(descriptor: AgentCLIDescriptor, candidates: [CLICandidate]) {
        self.descriptor = descriptor
        self.candidates = candidates
    }

    /// Whether the app has an adapter for this CLI (`RegisteredCLIAdapters`). A CLI found but not supported
    /// can be shown, never declared.
    public var isSupported: Bool {
        RegisteredCLIAdapters.names.contains(descriptor.cli)
    }

    /// The candidates the Operator may pick: those the descriptor did not refuse.
    public var selectable: [CLICandidate] {
        candidates.filter { $0.refusal == nil }
    }

    /// The first selectable candidate that is not an env-interpreted script; failing that the first
    /// selectable one; nil when there is none.
    public var preferred: CLICandidate? {
        let choices = selectable
        return choices.first { $0.envProgram == nil } ?? choices.first
    }
}

/// Everything discovery reads, as plain values.
public struct CLIDiscoveryEnvironment: Sendable {
    public var homeDirectory: String
    public var processPATH: String?
    public var loginShellPATH: String?
    public var etcDirectory: String
    public var descriptors: [AgentCLIDescriptor]
    public var commonLocations: [CLISearchLocation]

    public init(
        homeDirectory: String,
        processPATH: String?,
        loginShellPATH: String?,
        etcDirectory: String = "/etc",
        descriptors: [AgentCLIDescriptor] = AgentCLIDescriptors.all,
        commonLocations: [CLISearchLocation] = AgentCLIDescriptors.commonLocations
    ) {
        self.homeDirectory = homeDirectory
        self.processPATH = processPATH
        self.loginShellPATH = loginShellPATH
        self.etcDirectory = etcDirectory
        self.descriptors = descriptors
        self.commonLocations = commonLocations
    }
}

/// Finds agent CLIs on disk. Looks at files only: it never runs a CLI, so a find says nothing about whether
/// the CLI is ready; the Probe is the readiness gate.
public enum CLIDiscoverer {
    /// Discovers every descriptor in `environment`, in descriptor order, empty results included. Directories
    /// are searched in this order, and the first file found for a real path is the one kept:
    ///
    /// 1. the Operator's login-shell `PATH`, in order
    /// 2. the app process's `PATH`
    /// 3. `/etc/paths`, then `/etc/paths.d/*` by file name
    /// 4. the descriptor's own locations
    /// 5. the common locations: user-local, Homebrew, package managers, version-manager versions newest first
    /// 6. version-manager shims, last
    public static func discover(environment: CLIDiscoveryEnvironment) -> [CLIDiscovery] {
        let searchPath = ExecutableSearchPath.composed(
            loginShellPATH: environment.loginShellPATH,
            processPATH: environment.processPATH,
            systemPaths: ExecutableSearchPath.systemPaths(etcDirectory: environment.etcDirectory),
            locations: [],
            homeDirectory: environment.homeDirectory
        )
        return discover(
            descriptors: environment.descriptors,
            searchPath: searchPath,
            commonLocations: environment.commonLocations,
            homeDirectory: environment.homeDirectory
        )
    }

    /// Discovers each descriptor along `searchPath`, then the descriptor's own locations, then
    /// `commonLocations`.
    public static func discover(
        descriptors: [AgentCLIDescriptor],
        searchPath: ExecutableSearchPath,
        commonLocations: [CLISearchLocation] = [],
        homeDirectory: String
    ) -> [CLIDiscovery] {
        descriptors.map { descriptor in
            let path = searchPath.appending(
                locations: descriptor.locations + commonLocations, homeDirectory: homeDirectory
            )
            return CLIDiscovery(descriptor: descriptor, candidates: candidates(for: descriptor, along: path))
        }
    }

    private static func candidates(
        for descriptor: AgentCLIDescriptor, along searchPath: ExecutableSearchPath
    ) -> [CLICandidate] {
        var seen = Set<String>()
        var found: [CLICandidate] = []
        for entry in searchPath.entries {
            for name in descriptor.executableNames {
                let path = entry.directory == "/" ? "/\(name)" : "\(entry.directory)/\(name)"
                guard ExecutableFile.isRunnable(atPath: path),
                      let resolved = ExecutableFile.resolvedPath(path),
                      seen.insert(resolved).inserted else { continue }
                found.append(CLICandidate(
                    path: path, resolvedPath: resolved, source: entry.source,
                    refusal: descriptor.refusal(path, resolved), envProgram: envProgram(forPath: path)
                ))
            }
        }
        return found
    }

    private static func envProgram(forPath path: String) -> String? {
        guard let interpreter = ExecutableFile.interpreter(atPath: path), interpreter.viaEnv else { return nil }
        return interpreter.program
    }
}
