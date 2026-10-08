import Domain
import Foundation

/// Everything under `~/.config/yellowhammer`, loaded and validated at once: the machine-wide file and
/// every Project file, with per-Project failure isolation.
///
/// The machine-wide file is load-bearing for every Project, so its failure fails the whole load. A
/// Project that fails any rule is refused on its own and listed in ``invalidProjects`` with every
/// error found for it; its siblings still load. The one rule that spans Projects is working Repo
/// exclusivity: the same repository declared under `[[repos]]` by two Projects invalidates both
/// (OQ13). A Spec Source is not a Repo and may be shared by any number of Projects, including one that
/// declares the same repository as a working Repo (glossary → Spec Source).
public struct Configuration: Sendable {
    public var machine: MachineConfiguration
    /// Projects that passed every rule, sorted by id.
    public var projects: [ProjectConfiguration]
    /// Projects refused at load, sorted by file.
    public var invalidProjects: [InvalidProject]
    /// The merged Routing Table of every Project in ``projects``, keyed by Project id. Built once, at load.
    public var routingTables: [ProjectID: RoutingTable]

    public init(
        machine: MachineConfiguration,
        projects: [ProjectConfiguration],
        invalidProjects: [InvalidProject],
        routingTables: [ProjectID: RoutingTable]
    ) {
        self.machine = machine
        self.projects = projects
        self.invalidProjects = invalidProjects
        self.routingTables = routingTables
    }

    /// Returns the merged Routing Table for the given Project id, or nil for a Project that was not loaded,
    /// including one listed in ``invalidProjects``.
    public func routingTable(for id: ProjectID) -> RoutingTable? {
        routingTables[id]
    }
}

/// A Project file refused at load, with every error found for it.
public struct InvalidProject: Equatable, Sendable {
    public var file: String
    /// nil when the file did not decode far enough to know its id.
    public var id: ProjectID?
    /// Never empty.
    public var errors: [ConfigurationError]

    public init(file: String, id: ProjectID? = nil, errors: [ConfigurationError]) {
        self.file = file
        self.id = id
        self.errors = errors
    }
}

extension Configuration {
    /// `~/.config/yellowhammer` under the given home directory.
    public static func defaultDirectoryURL(homeDirectory: URL) -> URL {
        homeDirectory.appending(components: ".config", "yellowhammer", directoryHint: .isDirectory)
    }

    public static func load(homeDirectory: URL) throws(ConfigurationError) -> Configuration {
        try load(directory: defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    /// Reads `config.toml` and every `projects/*.toml` in the directory, in file-name order.
    ///
    /// A missing `projects` directory yields no Projects; what `yh` does about missing configuration
    /// is decided where an Act fires, not here.
    public static func load(directory: URL) throws(ConfigurationError) -> Configuration {
        try load(directory: directory, substitution: nil)
    }

    /// Loads `directory` as ``load(directory:)`` does, or returns nil when it holds no `config.toml`:
    /// a Mac where Setup has never run, which is not set up rather than misconfigured. A `config.toml`
    /// that exists but does not load still throws.
    public static func loadIfSetUp(directory: URL) throws(ConfigurationError) -> Configuration? {
        let machineFileURL = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: machineFileURL.path(percentEncoded: false)) else {
            return nil
        }
        return try load(directory: directory)
    }

    /// Loads `directory` exactly as ``load(directory:)`` does, except that wherever the loader would
    /// read `file` from disk — `config.toml`, or any `projects/<id>.toml` — it uses `text` instead.
    /// Used to validate an edit before it is written (``save(_:to:in:replacing:)``).
    public static func load(
        directory: URL, reading file: URL, as text: String
    ) throws(ConfigurationError) -> Configuration {
        try load(directory: directory, substitution: (file: file, text: text))
    }

    /// Loads `directory` as ``load(directory:)`` does, except that no Project's `change_type` or Message
    /// Template is validated: a refused one is recorded in ``ProjectConfiguration/unvalidatedTemplates``
    /// and its default stands in. For `yh project remove`, which validates only what it uses
    /// (spec: Configuration schema; OQ103(f)). It also accepts a Project whose `[board.linear] connection`
    /// names no registry entry (OQ109 item 10), or whose `[code_hosting] connection` names none, so such a
    /// Project can still be removed; a Project with no `connection` key is still refused. Everything else
    /// is checked as usual.
    public static func loadLeniently(directory: URL) throws(ConfigurationError) -> Configuration {
        try load(directory: directory, substitution: nil, lenientTemplates: true)
    }

    private static func load(
        directory: URL, substitution: (file: URL, text: String)?, lenientTemplates: Bool = false
    ) throws(ConfigurationError) -> Configuration {
        let machineFileURL = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        let machine = try loadMachine(at: machineFileURL, substitution: substitution)
        let declaredCLIAdapters = Set(machine.cliAdapters.map(\.name))
        // The lenient removal load accepts a connection name missing from either registry.
        let declaredLinearInstallations: Set<String>? = lenientTemplates
            ? nil : Set(machine.linearInstallations.map(\.name))
        let declaredCodeHostingConnections: Set<String>? = lenientTemplates
            ? nil : Set(machine.codeHostingConnections.map(\.name))

        var decoded: [(file: String, configuration: ProjectConfiguration)] = []
        var invalid: [InvalidProject] = []
        for url in projectFileURLs(in: directory) {
            let file = url.path(percentEncoded: false)
            do {
                let configuration = try loadProject(
                    at: url,
                    declared: DeclaredNames(
                        cliAdapters: declaredCLIAdapters, linearInstallations: declaredLinearInstallations,
                        codeHostingConnections: declaredCodeHostingConnections
                    ),
                    substitution: substitution, lenientTemplates: lenientTemplates
                )
                decoded.append((file, configuration))
            } catch {
                invalid.append(InvalidProject(file: file, id: nil, errors: [error]))
            }
        }
        // Project ids are unique across files already: the decoder refuses an id that differs from
        // its file stem, and a directory holds each file name once.
        let conflicts = workingRepoConflicts(among: decoded)
        var projects: [ProjectConfiguration] = []
        for (file, configuration) in decoded {
            if let errors = conflicts[file] {
                invalid.append(InvalidProject(file: file, id: configuration.id, errors: errors))
            } else {
                projects.append(configuration)
            }
        }
        let sortedProjects = projects.sorted { $0.id.rawValue < $1.id.rawValue }

        // Build the merged Routing Table for each valid Project.
        var routingTables: [ProjectID: RoutingTable] = [:]
        for project in sortedProjects {
            routingTables[project.id] = RoutingTable(base: machine.routingTable, overrides: project.routingOverrides)
        }

        return Configuration(
            machine: machine,
            projects: sortedProjects,
            invalidProjects: invalid.sorted { $0.file < $1.file },
            routingTables: routingTables
        )
    }

    /// Reads `url`, or parses `substitution`'s text in its place when `url` is the substituted file.
    private static func loadMachine(
        at url: URL, substitution: (file: URL, text: String)?
    ) throws(ConfigurationError) -> MachineConfiguration {
        if let substitution, samePath(substitution.file, url) {
            return try MachineConfiguration.parse(substitution.text, file: url.path(percentEncoded: false))
        }
        return try MachineConfiguration.load(contentsOf: url)
    }

    /// What the machine file declares, for a Project file to be checked against. A nil registry skips its
    /// check.
    private struct DeclaredNames {
        let cliAdapters: Set<String>
        let linearInstallations: Set<String>?
        let codeHostingConnections: Set<String>?
    }

    /// Reads `url`, or parses `substitution`'s text in its place when `url` is the substituted file.
    private static func loadProject(
        at url: URL, declared: DeclaredNames, substitution: (file: URL, text: String)?, lenientTemplates: Bool
    ) throws(ConfigurationError) -> ProjectConfiguration {
        if let substitution, samePath(substitution.file, url) {
            return try ProjectConfiguration.parse(
                substitution.text,
                file: url.path(percentEncoded: false),
                fileStem: url.deletingPathExtension().lastPathComponent,
                declaredCLIAdapters: declared.cliAdapters,
                declaredLinearInstallations: declared.linearInstallations,
                declaredCodeHostingConnections: declared.codeHostingConnections,
                lenientTemplates: lenientTemplates
            )
        }
        return try ProjectConfiguration.load(
            contentsOf: url, declaredCLIAdapters: declared.cliAdapters,
            declaredLinearInstallations: declared.linearInstallations,
            declaredCodeHostingConnections: declared.codeHostingConnections, lenientTemplates: lenientTemplates
        )
    }

    private static func projectFileURLs(in directory: URL) -> [URL] {
        let projectsDirectory = directory.appending(component: "projects", directoryHint: .isDirectory)
        let filenames = (try? FileManager.default.contentsOfDirectory(
            atPath: projectsDirectory.path(percentEncoded: false)
        )) ?? []
        return filenames
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { projectsDirectory.appending(component: $0, directoryHint: .notDirectory) }
            .filter { $0.pathExtension == "toml" }
    }

    // MARK: - Working Repo exclusivity

    /// Every Project that shares a working Repo path with another, keyed by file, with one error per
    /// conflicting Repo and other Project. Spec Sources do not take part: the declaration kind is
    /// checked, not just the path.
    private static func workingRepoConflicts(
        among projects: [(file: String, configuration: ProjectConfiguration)]
    ) -> [String: [ConfigurationError]] {
        struct Declaration {
            let file: String
            let id: ProjectID
            let repoIndex: Int
            let line: Int
        }
        var declarations: [String: [Declaration]] = [:]
        for (file, configuration) in projects {
            for (index, repo) in configuration.repos.enumerated() {
                let lines = configuration.repoPathLines
                let line = lines.indices.contains(index) ? lines[index] : 1
                declarations[normalizedPath(repo.path), default: []].append(
                    Declaration(file: file, id: configuration.id, repoIndex: index, line: line)
                )
            }
        }
        var errors: [String: [ConfigurationError]] = [:]
        for shared in declarations.values where shared.count > 1 {
            for declaration in shared {
                let others = shared.filter { $0.file != declaration.file }
                guard !others.isEmpty else { continue }
                for other in others.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                    errors[declaration.file, default: []].append(ConfigurationError(
                        file: declaration.file,
                        line: declaration.line,
                        key: "repos[\(declaration.repoIndex)].path",
                        reason: .workingRepoConflict(project: other.id, file: other.file)
                    ))
                }
            }
        }
        // Dictionary iteration above is unordered; the description names the other Project.
        return errors.mapValues { errors in
            errors.sorted { ($0.line, $0.description) < ($1.line, $1.description) }
        }
    }

    /// Whether two URLs name the same file, once standardized. Used to find the file a substituted
    /// read (``load(directory:reading:as:)``) applies to.
    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path(percentEncoded: false) == second.standardizedFileURL.path(percentEncoded: false)
    }

    /// Expands a leading `~` and removes `.`, `..` and a trailing slash. Purely lexical: the path
    /// need not exist and symlinks are not resolved, so two spellings of one directory through a
    /// symlink are not caught here.
    static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var standardized = URL(filePath: expanded).standardized.path(percentEncoded: false)
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }
}
