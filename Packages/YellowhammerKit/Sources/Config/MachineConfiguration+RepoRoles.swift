import Domain
import Foundation

extension MachineConfiguration {
    /// A copy with `name` (trimmed) declared as a Repo Role, after the existing declarations. No validation:
    /// the loader is the single validator, run when the result is saved. Ask ``declarationProblem(forRepoRoleNamed:)``
    /// first to put the reason in front of the Operator.
    public func declaring(repoRole name: String) -> MachineConfiguration {
        var copy = self
        copy.repoRoles.append(RepoRole(rawValue: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        return copy
    }

    /// A copy with every declaration of `repoRole` removed. No other validation: a Repo or Routing Entry
    /// still naming it keeps loading, as the Repo Role vocabulary is open.
    public func removing(repoRole: RepoRole) -> MachineConfiguration {
        var copy = self
        copy.repoRoles.removeAll { $0 == repoRole }
        return copy
    }

    /// Why `name` (trimmed) cannot be declared as a Repo Role, in words for the Operator; nil when it can.
    public func declarationProblem(forRepoRoleNamed name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Give the Repo Role a name."
        }
        guard RepoRole.isValidName(trimmed) else {
            return "A Repo Role name may contain only lowercase letters, digits, \u{201C}_\u{201D} and "
                + "\u{201C}-\u{201D}, and must start with a letter or a digit."
        }
        let role = RepoRole(rawValue: trimmed)
        guard !role.isStandard else {
            return "\(trimmed) is a standard Repo Role, offered already."
        }
        guard !repoRoles.contains(role) else {
            return "\(trimmed) is already declared."
        }
        return nil
    }

    /// The Repo Roles every picker offers on this Mac without a Project: the standard ones in their order,
    /// then the declared ones in file order, each once.
    public var offeredRepoRoles: [RepoRole] {
        Self.deduplicated(RepoRole.standard + repoRoles)
    }

    /// The Repo Roles the app's pickers offer: the standard ones in their order, then every other role sorted
    /// by name, each once, drawn from the declared Repo Roles, every Repo of `projects`, and every Repo Role
    /// the base Routing Table or a Project's routing overrides name.
    public func offeredRepoRoles(with projects: [ProjectConfiguration]) -> [RepoRole] {
        var others = Set(repoRoles)
        for project in projects {
            others.formUnion(project.repos.map(\.role))
            others.formUnion(project.routingOverrides.compactMap(\.repoRole.namedRole))
        }
        others.formUnion(routingTable.compactMap(\.repoRole.namedRole))
        let extra = others.subtracting(RepoRole.standard).sorted { $0.rawValue < $1.rawValue }
        return RepoRole.standard + extra
    }

    /// The names of the Projects, in `projects` order and each once, where some Repo has `repoRole` or some
    /// routing override names it.
    public func projectsUsing(repoRole: RepoRole, in projects: [ProjectConfiguration]) -> [String] {
        projects.filter { project in
            project.repos.contains { $0.role == repoRole }
                || project.routingOverrides.contains { $0.repoRole == .role(repoRole) }
        }
        .map(\.name)
    }

    /// Whether some base Routing Table entry names `repoRole`.
    public func baseRoutingTableNames(repoRole: RepoRole) -> Bool {
        routingTable.contains { $0.repoRole == .role(repoRole) }
    }

    private static func deduplicated(_ roles: [RepoRole]) -> [RepoRole] {
        var seen = Set<RepoRole>()
        return roles.filter { seen.insert($0).inserted }
    }
}

extension RepoRoleMatch {
    /// The Repo Role this match names, or nil for `.any`.
    fileprivate var namedRole: RepoRole? {
        guard case .role(let role) = self else { return nil }
        return role
    }
}
