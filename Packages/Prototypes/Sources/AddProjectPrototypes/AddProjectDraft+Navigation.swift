#if DEBUG
import Foundation

// MARK: - Navigation

extension AddProjectDraft {
    var isFirstStep: Bool { step == WizardStep.allCases.first }
    var isLastStep: Bool { step == WizardStep.allCases.last }
    var canContinue: Bool { isComplete(step) }

    var continueTitle: String { isLastStep ? "Add Project" : "Continue" }

    mutating func goBack() {
        guard let previous = WizardStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Advances, or runs setup from the last step.
    mutating func goForward() {
        guard canContinue else { return }
        if let next = WizardStep(rawValue: step.rawValue + 1) {
            step = next
            reached = max(reached, next)
            visited.insert(next)
        } else {
            runSetup()
        }
    }

    /// Jumps to a step already reached; a variant decides whether it allows jumping ahead.
    mutating func go(to target: WizardStep, allowingAhead: Bool = false) {
        guard allowingAhead || target <= reached else { return }
        visited.insert(step)
        step = target
        reached = max(reached, target)
        visited.insert(target)
    }

    /// Sets the name, and the id with it until the Operator types an id of their own.
    mutating func setName(_ newName: String) {
        name = newName
        if !idEdited { projectID = Self.slug(newName) }
    }

    mutating func setProjectID(_ newID: String) {
        projectID = newID
        idEdited = !newID.isEmpty
        idConfirmed = false
    }

    /// "Acme Mobile!" becomes "acme-mobile".
    static func slug(_ name: String) -> String {
        name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
    }

    mutating func runSetup() {
        guard isComplete else { return }
        run = runFails ? .failed : .succeeded
    }

    /// The fixture folder picker: the next fixture path not already declared.
    mutating func addRepo() {
        let declared = Set(repos.map(\.path))
        let path = AddProjectFixtures.pickablePaths.first { !declared.contains($0) }
            ?? "\(AddProjectFixtures.home)/dev/acme/acme-\(repos.count + 1)"
        repos.append(RepoDraft(path: path, role: AddProjectFixtures.guessedRole(for: path)))
    }

    mutating func chooseSpecSource() {
        useSpecSource("\(AddProjectFixtures.home)/dev/acme/acme-spec")
    }

    /// Makes a shared folder the one specification source, clearing any Repo's spec role.
    mutating func useSpecSource(_ path: String) {
        specChoice = .path
        specSourcePath = path
        for index in repos.indices where repos[index].role == "spec" {
            repos[index].role = AddProjectFixtures.workingRole(for: repos[index].path)
        }
    }

    /// Makes one Repo the one specification source: role "spec" on it alone, and no Spec Source.
    mutating func useSpecRepo(_ id: RepoDraft.ID) {
        specChoice = .repo
        specSourcePath = ""
        for index in repos.indices {
            if repos[index].id == id {
                repos[index].role = "spec"
                if repos[index].check.isEmpty { repos[index].check = "none" }
            } else if repos[index].role == "spec" {
                repos[index].role = AddProjectFixtures.workingRole(for: repos[index].path)
            }
        }
    }

    /// Declares the spec checkout as a Repo of this Project and makes it the specification source.
    mutating func addSpecRepo() {
        let path = "\(AddProjectFixtures.home)/dev/acme/acme-spec"
        if let existing = repos.first(where: { $0.path == path }) {
            useSpecRepo(existing.id)
            return
        }
        let repo = RepoDraft(path: path, role: "spec", check: "none")
        repos.append(repo)
        useSpecRepo(repo.id)
    }

    mutating func chooseExportDirectory() {
        exportDirectory = "\(AddProjectFixtures.home)/Desktop/acme-jobs"
    }
}
#endif
