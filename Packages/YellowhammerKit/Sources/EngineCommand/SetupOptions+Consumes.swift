import ArgumentParser
import Config
import Domain

extension SetupOptions {
    /// Folds each `--consumes consumer,producer,via` into the `consumes` of the `--repo` declaration it names,
    /// in `--consumes` order. Whether the producer exists, the edge repeats or the edges form a cycle is the
    /// loader's to refuse, when the Project's shape is validated.
    static func foldConsumes(_ raw: [String], into repos: [RepoDeclaration]) throws -> [RepoDeclaration] {
        var repos = repos
        for entry in raw {
            let (consumer, dependency) = try parseConsumes(entry)
            guard let index = repos.firstIndex(where: { $0.name == consumer }) else {
                throw ValidationError("--consumes names consumer \"\(consumer)\", which was not declared with --repo")
            }
            repos[index].consumes.append(dependency)
        }
        return repos
    }

    /// `consumer,producer,via`, three non-empty fields; `via` is `mainline` or `tag`.
    private static func parseConsumes(_ raw: String) throws -> (consumer: String, dependency: RepoDependency) {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError("--consumes must be \"consumer,producer,via\", got \"\(raw)\"")
        }
        guard let via = RepoDependencyVia(rawValue: parts[2]) else {
            throw ValidationError("--consumes via must be \"mainline\" or \"tag\", got \"\(parts[2])\"")
        }
        return (parts[0], RepoDependency(producer: parts[1], via: via))
    }
}
