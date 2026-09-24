import Config
import Domain
import Foundation
import Testing

/// Refusals through ``Configuration/save(_:to:in:replacing:)``: the loader's own errors, and that
/// nothing is written on refusal. Round trips live in ``ConfigurationEditingTests``.
@Suite("Configuration editing refusals")
struct ConfigurationEditingRefusalTests {
    @Test("A Bound of 0 is refused with the loader's notPositive message, and nothing is written")
    func boundZeroIsRefused() throws {
        try expectProjectEditRefused(id: "boundzero") { draft in
            draft.bounds.reviewRoundsMax = "0"
        } assertReason: { reason, key in
            guard case .notPositive(let value) = reason else {
                Issue.record("expected .notPositive, got \(reason)")
                return
            }
            #expect(value == 0)
            #expect(key == "limits.review_rounds_max")
        }
    }

    @Test("A non-numeric Bound is refused with the loader's typeMismatch message")
    func boundNonNumericIsRefused() throws {
        try expectProjectEditRefused(id: "boundabc") { draft in
            draft.bounds.attemptsPerCard = "abc"
        } assertReason: { reason, _ in
            guard case .typeMismatch(let expected, _) = reason else {
                Issue.record("expected .typeMismatch, got \(reason)")
                return
            }
            #expect(expected == "integer")
        }
    }

    @Test("A routing override naming an undeclared CLI is refused")
    func overrideUndeclaredCLIIsRefused() throws {
        try expectProjectEditRefused(id: "undeclaredcli") { draft in
            draft.routingOverrides = [
                RoutingEntryDraft(route: RouteDraft(cli: "gemini", model: "flash", effort: "medium"))
            ]
        } assertReason: { reason, _ in
            guard case .undeclaredCLIAdapter(let cli) = reason else {
                Issue.record("expected .undeclaredCLIAdapter, got \(reason)")
                return
            }
            #expect(cli == "gemini")
        }
    }

    @Test("An invalid Kind is refused")
    func invalidKindIsRefused() throws {
        try expectProjectEditRefused(id: "invalidkind") { draft in
            draft.routingOverrides = [
                RoutingEntryDraft(kind: "a..b", route: RouteDraft(cli: "claude", model: "sonnet", effort: "medium"))
            ]
        } assertReason: { reason, _ in
            guard case .invalidKind(let value) = reason else {
                Issue.record("expected .invalidKind, got \(reason)")
                return
            }
            #expect(value == "a..b")
        }
    }

    @Test("An empty Repo check is refused")
    func emptyCheckIsRefused() throws {
        try expectProjectEditRefused(id: "emptycheck") { draft in
            draft.repos = [RepoDraft(name: "backend", path: "~/dev/emptycheck-backend", role: "backend", check: "")]
        } assertReason: { reason, _ in
            guard case .emptyString = reason else {
                Issue.record("expected .emptyString, got \(reason)")
                return
            }
        }
    }

    @Test("A second specification source is refused")
    func secondSpecSourceIsRefused() throws {
        try expectProjectEditRefused(id: "secondspec") { draft in
            draft.repos.append(
                RepoDraft(name: "spec-repo", path: "~/dev/secondspec-spec-repo", role: "spec", check: "none")
            )
        } assertReason: { reason, _ in
            guard case .secondSpecificationSource = reason else {
                Issue.record("expected .secondSpecificationSource, got \(reason)")
                return
            }
        }
    }

    @Test("A Repo path another Project already declares as a working Repo is refused; both files are unchanged")
    func workingRepoConflictIsRefusedAndBothFilesUnchanged() throws {
        let machine = try testEditingMachine()
        let projectA = try testEditingProject(
            id: "conflicta",
            repos: [RepoDeclaration(name: "backend", path: "~/dev/conflict-a-backend", role: .backend, check: .none)]
        )
        let projectB = try testEditingProject(
            id: "conflictb",
            repos: [RepoDeclaration(name: "backend", path: "~/dev/conflict-b-backend", role: .backend, check: .none)]
        )
        let directory = try makeEditingDirectory(machine: machine, projects: [projectA, projectB])
        defer { cleanupEditingDirectory(directory) }

        let fileA = editingProjectFileURL(directory, "conflicta")
        let fileB = editingProjectFileURL(directory, "conflictb")
        let originalTextA = try String(contentsOf: fileA, encoding: .utf8)
        let originalTextB = try String(contentsOf: fileB, encoding: .utf8)

        var draft = ProjectFileDraft(projectA)
        draft.repos[0].path = "~/dev/conflict-b-backend"
        let newText = draft.renderedTOML

        let result = Result { () throws(ConfigurationEditError) in
            try Configuration.save(newText, to: fileA, in: directory, replacing: originalTextA)
        }
        guard case .failure(let error) = result, case .refused(let errors) = error else {
            Issue.record("expected .refused")
            return
        }
        #expect(!errors.isEmpty)
        #expect(errors.allSatisfy {
            if case .workingRepoConflict = $0.reason { return true }
            return false
        })

        #expect((try String(contentsOf: fileA, encoding: .utf8)) == originalTextA)
        #expect((try String(contentsOf: fileB, encoding: .utf8)) == originalTextB)
    }

    @Test("A machine edit that drops a CLI a sibling Project's override needs is refused, naming that Project's file")
    func machineEditInvalidatingSiblingIsRefused() throws {
        let machineWithGemini = try testEditingMachine(cliAdapters: ["claude", "codex", "gemini"])
        let project = try testEditingProject(
            id: "dependsongemini",
            routingOverrides: [RoutingEntry(route: try editingRoute("gemini", "flash", "medium"))]
        )
        let directory = try makeEditingDirectory(machine: machineWithGemini, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingMachineFileURL(directory)
        let originalText = try String(contentsOf: file, encoding: .utf8)

        let machineWithoutGemini = try testEditingMachine(cliAdapters: ["claude", "codex"])
        let newText = machineWithoutGemini.renderedTOML

        let result = Result { () throws(ConfigurationEditError) in
            try Configuration.save(newText, to: file, in: directory, replacing: originalText)
        }
        guard case .failure(let error) = result, case .refused(let errors) = error else {
            Issue.record("expected .refused")
            return
        }
        let projectFile = editingProjectFileURL(directory, "dependsongemini").path(percentEncoded: false)
        #expect(errors.contains { $0.file == projectFile })
        #expect(errors.contains {
            if case .undeclaredCLIAdapter("gemini") = $0.reason { return true }
            return false
        })

        // Nothing written: the machine file is unchanged.
        #expect((try String(contentsOf: file, encoding: .utf8)) == originalText)
    }

    // MARK: - changedOnDisk

    @Test("A file modified on disk since it was opened refuses the save as changedOnDisk")
    func changedOnDiskIsDetected() throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: "changed")
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, "changed")
        let originalText = try String(contentsOf: file, encoding: .utf8)

        // Someone else edits the file directly, after this "session" read `originalText`.
        try (originalText + "\n# a hand edit\n").write(to: file, atomically: true, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        draft.name = "New Name"

        let result = Result { () throws(ConfigurationEditError) in
            try Configuration.save(draft.renderedTOML, to: file, in: directory, replacing: originalText)
        }
        guard case .failure(let error) = result else {
            Issue.record("expected changedOnDisk")
            return
        }
        #expect(error == .changedOnDisk(file: file.path(percentEncoded: false)))
    }

    // MARK: - Test helper

    private func expectProjectEditRefused(
        id: String,
        edit: (inout ProjectFileDraft) -> Void,
        assertReason: (ConfigurationError.Reason, String?) -> Void
    ) throws {
        let machine = try testEditingMachine()
        let project = try testEditingProject(id: id)
        let directory = try makeEditingDirectory(machine: machine, projects: [project])
        defer { cleanupEditingDirectory(directory) }

        let file = editingProjectFileURL(directory, id)
        let originalText = try String(contentsOf: file, encoding: .utf8)

        var draft = ProjectFileDraft(project)
        edit(&draft)
        let newText = draft.renderedTOML

        let result = Result { () throws(ConfigurationEditError) in
            try Configuration.save(newText, to: file, in: directory, replacing: originalText)
        }
        guard case .failure(let error) = result, case .refused(let errors) = error else {
            Issue.record("expected .refused")
            return
        }
        #expect(!errors.isEmpty)
        assertReason(errors[0].reason, errors[0].key)

        // Nothing was written.
        #expect((try String(contentsOf: file, encoding: .utf8)) == originalText)
    }
}
