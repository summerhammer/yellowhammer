import Domain
import Foundation

/// What the Add Project wizard knows about its surroundings: the Projects, Repos, Spec Sources and
/// Journals already on this Mac, and the Linear teams. Plain values, so the wizard validates against
/// them without touching the disk.
public struct AddProjectContext: Equatable, Sendable {
    /// The id of every `projects/<id>.toml` file, refused ones included: an id whose file merely exists is taken.
    public var existingProjectIDs: Set<String>
    /// A declared Repo's normalized path, to the name of the Project that owns it.
    public var repoOwners: [String: String]
    /// A Spec Source's normalized path, to the names of the Projects reading it. Sharing one is normal.
    public var specSourceReaders: [String: [String]]
    /// The ids that still have a Journal on disk.
    public var journalProjectIDs: Set<String>
    /// The Linear teams `yh setup --print-choices` returned.
    public var teams: [SetupChoices.Team]
    /// The active Linear projects `yh setup --print-choices` returned, in the board's order. // glossary:ignore GL001
    public var linearProjects: [SetupChoices.LinearProject] // glossary:ignore GL001

    public init(
        existingProjectIDs: Set<String> = [],
        repoOwners: [String: String] = [:],
        specSourceReaders: [String: [String]] = [:],
        journalProjectIDs: Set<String> = [],
        teams: [SetupChoices.Team] = [],
        linearProjects: [SetupChoices.LinearProject] = []
    ) {
        self.linearProjects = linearProjects
        self.existingProjectIDs = existingProjectIDs
        self.repoOwners = repoOwners
        self.specSourceReaders = specSourceReaders
        self.journalProjectIDs = journalProjectIDs
        self.teams = teams
    }

    /// Builds the maps from the loaded Projects; `projectFileIDs` adds the ids of files that did not load.
    public init(
        configuration: Configuration,
        projectFileIDs: Set<String>,
        journalProjectIDs: Set<String>,
        teams: [SetupChoices.Team] = [],
        linearProjects: [SetupChoices.LinearProject] = []
    ) {
        var owners: [String: String] = [:]
        var readers: [String: [String]] = [:]
        for project in configuration.projects {
            for repo in project.repos {
                owners[Self.normalizedPath(repo.path)] = project.name
            }
            if let specSource = project.specSource {
                readers[Self.normalizedPath(specSource), default: []].append(project.name)
            }
        }
        self.init(
            existingProjectIDs: projectFileIDs.union(configuration.projects.map(\.id.rawValue)),
            repoOwners: owners,
            specSourceReaders: readers,
            journalProjectIDs: journalProjectIDs,
            teams: teams,
            linearProjects: linearProjects
        )
    }

    /// Expands `~` and standardizes, so `~/dev/a` and `/Users/me/dev/a/` compare equal.
    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(filePath: expanded).standardized.path(percentEncoded: false)
    }
}
