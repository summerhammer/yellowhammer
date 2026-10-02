#if DEBUG
import Foundation

struct LinearProjectFixture: Identifiable, Hashable { // glossary:ignore GL001
    let id: String
    let name: String
    let teamName: String
}

struct TeamFixture: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

/// What `yh --print-choices` and the sibling Projects' configuration would offer, as fixtures.
enum AddProjectFixtures {
    static let home = "/Users/operator"

    static let linearProjects: [LinearProjectFixture] = [ // glossary:ignore GL001
        LinearProjectFixture(id: "8f1c2e7a", name: "Acme Platform", teamName: "Acme"),
        LinearProjectFixture(id: "4b9d0a13", name: "Acme Mobile Relaunch", teamName: "Acme"),
        LinearProjectFixture(id: "c27e55f0", name: "Billing Revamp", teamName: "Payments")
    ]

    static let teams: [TeamFixture] = [
        TeamFixture(key: "ACM", name: "Acme"),
        TeamFixture(key: "PAY", name: "Payments"),
        TeamFixture(key: "OPS", name: "Operations")
    ]

    /// Ids the sibling Projects already use.
    static let existingProjectIDs: Set<String> = ["beta-service", "docs-site"]

    /// Ids of removed Projects whose Journal is still on disk: a Project declared with one of these
    /// reopens that Journal and continues its history.
    static let existingJournalIDs: Set<String> = ["legacy-api"]

    /// Spec Sources other Projects already read, by path, with the Projects that read them. A Spec
    /// Source is read-only, so sharing one is normal.
    static let sharedSpecSources: [(path: String, readBy: [String])] = [
        ("\(home)/dev/acme/acme-spec", ["Beta Service"]),
        ("\(home)/dev/platform/platform-spec", ["Beta Service", "Docs Site"])
    ]

    /// Working Repos already declared by a sibling Project, by path, with that Project's name.
    static let workingRepos: [String: String] = [
        "\(home)/dev/acme/acme-web": "Beta Service",
        "\(home)/dev/docs/site": "Docs Site"
    ]

    /// The folders the fixture "Choose…" offers, in order.
    static let pickablePaths = [
        "\(home)/dev/acme/acme-backend",
        "\(home)/dev/acme/acme-mobile",
        "\(home)/dev/acme/acme-web",
        "\(home)/dev/acme/acme-infra",
        "\(home)/dev/acme/acme-spec"
    ]

    static let roles = ["backend", "mobile", "web", "infra", "spec"]

    static let checkSuggestions = ["make test", "swift test", "npm test", "./scripts/check", "none"]

    static func guessedRole(for path: String) -> String {
        roles.first { path.hasSuffix($0) } ?? ""
    }

    /// The guessed role, never "spec": what a Repo goes back to when it stops being the spec.
    static func workingRole(for path: String) -> String {
        let role = guessedRole(for: path)
        return role == "spec" ? "" : role
    }
}

/// Starting states for the Playground and the Gallery.
enum AddProjectScenario: String, CaseIterable, Identifiable {
    case fresh = "Fresh"
    case repoConflict = "Repo conflict"
    case reusedID = "Reused id"
    case specClash = "Two spec sources"
    case readyToRun = "Ready to add"
    case added = "Added"
    case failed = "Run failed"

    var id: Self { self }

    var draft: AddProjectDraft {
        switch self {
        case .fresh:
            return AddProjectDraft()
        case .repoConflict:
            // The wireframe: step 2, two good Repos and one owned by Beta Service.
            var draft = Self.named
            draft.step = .repos
            draft.reached = .repos
            draft.visited = [.project, .repos]
            draft.repos = Self.wireframeRepos
            return draft
        case .reusedID:
            // A removed Project's Journal is still on disk under this id.
            var draft = AddProjectDraft()
            draft.setName("Legacy API")
            return draft
        case .specClash:
            var draft = Self.named
            draft.step = .specSource
            draft.reached = .specSource
            draft.visited = [.project, .repos, .specSource]
            draft.repos = Array(Self.wireframeRepos.prefix(2)) + [Self.specRepo]
            draft.specSourcePath = "\(AddProjectFixtures.home)/dev/acme/acme-spec-shared"
            return draft
        case .readyToRun:
            return Self.complete
        case .added:
            var draft = Self.complete
            draft.run = .succeeded
            return draft
        case .failed:
            var draft = Self.complete
            draft.runFails = true
            draft.run = .failed
            return draft
        }
    }

    private static var named: AddProjectDraft {
        var draft = AddProjectDraft()
        draft.setName("Acme")
        draft.idConfirmed = true
        draft.linearProjectID = AddProjectFixtures.linearProjects[0].id
        return draft
    }

    private static var complete: AddProjectDraft {
        var draft = named
        draft.step = .jobs
        draft.reached = .jobs
        draft.visited = Set(WizardStep.allCases)
        draft.idConfirmed = true
        draft.repos = Array(wireframeRepos.prefix(2))
        draft.chooseSpecSource()
        return draft
    }

    private static let wireframeRepos = [
        RepoDraft(path: "\(AddProjectFixtures.home)/dev/acme/acme-backend", role: "backend", check: "make test"),
        RepoDraft(path: "\(AddProjectFixtures.home)/dev/acme/acme-mobile", role: "mobile", check: "swift test"),
        RepoDraft(path: "\(AddProjectFixtures.home)/dev/acme/acme-web", role: "web", check: "npm test")
    ]

    private static let specRepo = RepoDraft(
        path: "\(AddProjectFixtures.home)/dev/acme/acme-spec", role: "spec", check: "none"
    )
}
#endif
