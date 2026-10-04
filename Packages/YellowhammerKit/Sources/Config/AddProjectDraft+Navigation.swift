import Foundation

// MARK: - Navigation

extension AddProjectDraft {
    /// Where a step stands in the hub, where any step can be opened: done when complete, a problem once
    /// left and still incomplete, current when open, untouched otherwise.
    public func status(of step: Step) -> StepStatus {
        if isComplete(step) { return .done }
        if left.contains(step) { return .problem }
        return step == self.step ? .current : .upcoming
    }

    /// Opens any step. The one being left and the target both count as visited, and the one being left
    /// starts showing its problems.
    public mutating func go(to target: Step) {
        visited.insert(step)
        if target != step { left.insert(step) }
        step = target
        visited.insert(target)
    }

    /// Sets the name, and the id with it until the Operator types an id of their own.
    public mutating func setName(_ newName: String) {
        name = newName
        if !idEdited { projectID = Self.slug(newName) }
    }

    public mutating func setProjectID(_ newID: String) {
        projectID = newID
        idEdited = !newID.isEmpty
        idConfirmed = false
    }

    /// "Acme Mobile!" becomes "acme-mobile". Only ASCII `[a-z0-9-]` survives, so a slug is a valid
    /// Project id or empty; any other character, accented letters included, is a separator.
    public static func slug(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9": Character(scalar)
            default: "-"
            }
        })
        .split(separator: "-")
        .joined(separator: "-")
    }

    /// Selects the Linear workspace by its local name. A different workspace clears what belonged to the
    /// previous one: its teams, its Linear projects and the choices made from them.
    public mutating func selectLinearInstallation(_ name: String) {
        guard linearInstallationName != name else { return }
        linearInstallationName = name
        teamKey = nil
        linearProjectID = ""
        context.teams = []
        context.linearProjects = []
    }

    // MARK: Repos and the Spec Source

    public static let suggestedRoles = ["backend", "mobile", "web", "infra", "spec"]

    public static let suggestedChecks = ["make test", "swift test", "npm test", "./scripts/check", "none"]

    /// The suggested role a folder's name ends with, or none.
    public static func guessedRole(for path: String) -> String {
        suggestedRoles.first { path.hasSuffix($0) } ?? ""
    }

    /// The guessed role, never "spec": what a Repo goes back to when it stops being the spec.
    public static func workingRole(for path: String) -> String {
        let role = guessedRole(for: path)
        return role == "spec" ? "" : role
    }

    public mutating func addRepo(path: String) {
        repos.append(Repo(path: path, role: Self.guessedRole(for: path)))
    }

    public mutating func removeRepo(_ id: Repo.ID) {
        repos.removeAll { $0.id == id }
    }

    /// Makes a shared folder the one Spec Source, clearing any Repo's spec role.
    public mutating func useSpecSource(_ path: String) {
        specChoice = .path
        specSourcePath = path
        for index in repos.indices where repos[index].role == "spec" {
            repos[index].role = Self.workingRole(for: repos[index].path)
        }
    }

    /// Makes one Repo the Spec Source: role "spec" on it alone, and no Spec Source path.
    public mutating func useSpecRepo(_ id: Repo.ID) {
        specChoice = .repo
        specSourcePath = ""
        for index in repos.indices {
            if repos[index].id == id {
                repos[index].role = "spec"
                if repos[index].check.isEmpty { repos[index].check = "none" }
            } else if repos[index].role == "spec" {
                repos[index].role = Self.workingRole(for: repos[index].path)
            }
        }
    }

    /// Declares the spec checkout as a Repo of this Project and makes it the Spec Source.
    public mutating func addSpecRepo(path: String) {
        let normalized = AddProjectContext.normalizedPath(path)
        if let existing = repos.first(where: { AddProjectContext.normalizedPath($0.path) == normalized }) {
            useSpecRepo(existing.id)
            return
        }
        let repo = Repo(path: path, role: "spec", check: "none")
        repos.append(repo)
        useSpecRepo(repo.id)
    }
}
