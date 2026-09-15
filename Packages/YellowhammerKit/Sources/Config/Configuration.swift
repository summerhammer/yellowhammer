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

    public init(machine: MachineConfiguration, projects: [ProjectConfiguration], invalidProjects: [InvalidProject]) {
        self.machine = machine
        self.projects = projects
        self.invalidProjects = invalidProjects
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
        let machine = try MachineConfiguration.load(
            contentsOf: directory.appending(component: "config.toml", directoryHint: .notDirectory)
        )
        let declaredCLIAdapters = Set(machine.cliAdapters.map(\.name))
        var decoded: [(file: String, configuration: ProjectConfiguration)] = []
        var invalid: [InvalidProject] = []
        for url in projectFileURLs(in: directory) {
            let file = url.path(percentEncoded: false)
            do {
                let configuration = try ProjectConfiguration.load(
                    contentsOf: url, declaredCLIAdapters: declaredCLIAdapters
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
        return Configuration(
            machine: machine,
            projects: projects.sorted { $0.id.rawValue < $1.id.rawValue },
            invalidProjects: invalid.sorted { $0.file < $1.file }
        )
    }

    private static func projectFileURLs(in directory: URL) -> [URL] {
        let projectsDirectory = directory.appending(component: "projects", directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
