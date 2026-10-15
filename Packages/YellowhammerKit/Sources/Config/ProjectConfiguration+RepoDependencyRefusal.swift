import Domain

extension ProjectConfiguration {
    /// Why the loader would refuse the Repo Dependencies declared on `repos`, or nil when it would not: the
    /// `repos` rendered into a minimal Project and parsed back through the one loader, so the setup flows give
    /// the Operator the loader's own message and never a second opinion. Only the refusals about the
    /// dependencies themselves are reported; anything else wrong with the Repos is for the full shape check.
    public static func repoDependencyRefusal(repos: [RepoDeclaration]) -> String? {
        guard let id = ProjectID(rawValue: "repo-dependency-check") else { return nil }
        let project = ProjectConfiguration(
            id: id, name: "Repo Dependency check", linearInstallationName: "check", linearProject: "check",
            codeHostingConnectionName: "check", specSource: repos.contains { $0.role == .spec } ? nil : "spec",
            repos: repos
        )
        do {
            _ = try parse(project.renderedTOML, file: "repos")
            return nil
        } catch {
            return isRepoDependencyRefusal(error.reason) ? error.reason.description : nil
        }
    }

    private static func isRepoDependencyRefusal(_ reason: ConfigurationError.Reason) -> Bool {
        switch reason {
        case .unknownRepoDependencyProducer, .selfRepoDependency, .duplicateRepoDependency,
             .repoDependencyCycle, .invalidRepoDependencyVia:
            true
        default:
            false
        }
    }
}
