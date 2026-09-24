import Config
import Domain

/// One Project's declaration, built either from `--init` options or interactive prompts, then written
/// through the one shared path in `Setup+ProjectFile.swift`. Neither source duplicates the write.
struct ProjectDeclaration {
    enum LinearProjectChoice {
        case existing(String)
        case createInTeam(key: String)
    }

    let id: ProjectID
    let name: String
    let linearProject: LinearProjectChoice
    let specSource: String?
    let repos: [RepoDeclaration]
}
