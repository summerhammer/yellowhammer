import Domain
import Foundation
import Repositories
import Testing

@Suite("Provenance diff tester tests")
struct ProvenanceDiffTests {

    @Test("Untouched path: mainline moved with unrelated commits, recorded file unchanged -> clean")
    func untouchedPathMainlineMoved() async throws {
        let fixture = GitFixture(name: "prov-untouched-1")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "contract.swift", content: "protocol Contract {}", message: "v1")
        _ = try fixture.commit(filename: "unrelated.swift", content: "struct Unrelated {}", message: "v2")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: ["contract.swift"], recordedCommit: c1)

        #expect(result.verdict == .clean)
        #expect(result.isStillGood == true)
        #expect(result.isDiverged == false)
        #expect(result.changedPaths == [])
        #expect(result.recordedCommit == c1)
    }

    @Test("Touched path: recorded file modified on mainline -> stale with changedPaths and isDiverged")
    func touchedPathModified() async throws {
        let fixture = GitFixture(name: "prov-touched-2")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(
            filename: "contract.swift",
            content: "protocol Contract { func a() }",
            message: "v1"
        )
        _ = try fixture.commit(
            filename: "contract.swift",
            content: "protocol Contract { func b() }",
            message: "v2"
        )

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: ["contract.swift"], recordedCommit: c1)

        #expect(result.verdict == .stale(changedPaths: ["contract.swift"]))
        #expect(result.isDiverged == true)
        #expect(result.isStillGood == false)
        #expect(result.changedPaths == ["contract.swift"])
    }

    @Test("Renamed path: recorded file was renamed on mainline -> stale with original recorded path")
    func renamedPathOnMainline() async throws {
        let fixture = GitFixture(name: "prov-renamed-3")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "old_contract.swift", content: "protocol Contract {}", message: "v1")
        _ = fixture.run(["mv", "old_contract.swift", "new_contract.swift"])
        _ = fixture.run(["add", "."])
        _ = fixture.run(["commit", "-m", "rename contract"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: ["old_contract.swift"], recordedCommit: c1)

        #expect(result.verdict == .stale(changedPaths: ["old_contract.swift"]))
        #expect(result.isDiverged == true)
        #expect(result.changedPaths == ["old_contract.swift"])
    }

    @Test("Deleted path: recorded file deleted on mainline -> stale")
    func deletedPathOnMainline() async throws {
        let fixture = GitFixture(name: "prov-deleted-4")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "to_delete.swift", content: "protocol ToDelete {}", message: "v1")
        _ = fixture.run(["rm", "to_delete.swift"])
        _ = fixture.run(["commit", "-m", "delete contract"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: ["to_delete.swift"], recordedCommit: c1)

        #expect(result.verdict == .stale(changedPaths: ["to_delete.swift"]))
        #expect(result.isDiverged == true)
        #expect(result.changedPaths == ["to_delete.swift"])
    }

    @Test("Multiple paths: some touched, some untouched -> reports exactly touched paths sorted")
    func multiplePathsSomeTouched() async throws {
        let fixture = GitFixture(name: "prov-multi-5")
        fixture.initRepo(defaultBranch: "main")

        _ = try fixture.commit(filename: "z_untouched.swift", content: "protocol Z {}", message: "v0")
        _ = try fixture.commit(filename: "b_touched.swift", content: "protocol B {}", message: "v0")
        let c1 = try fixture.commit(filename: "a_touched.swift", content: "protocol A {}", message: "v1")

        _ = try fixture.commit(filename: "a_touched.swift", content: "protocol A modified {}", message: "v2-a")
        _ = try fixture.commit(filename: "b_touched.swift", content: "protocol B modified {}", message: "v2-b")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(
            repository: repo,
            paths: ["z_untouched.swift", "b_touched.swift", "a_touched.swift"],
            recordedCommit: c1
        )

        #expect(result.verdict == .stale(changedPaths: ["a_touched.swift", "b_touched.swift"]))
        #expect(result.isDiverged == true)
        #expect(result.changedPaths == ["a_touched.swift", "b_touched.swift"])
    }

    @Test("Empty paths list -> clean")
    func emptyPathsList() async throws {
        let fixture = GitFixture(name: "prov-empty-paths-6")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "file.swift", content: "v1", message: "v1")
        _ = try fixture.commit(filename: "file.swift", content: "v2", message: "v2")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: [], recordedCommit: c1)

        #expect(result.verdict == .clean)
        #expect(result.isStillGood == true)
        #expect(result.isDiverged == false)
        #expect(result.changedPaths == [])
    }

    @Test("Identical commit: recorded commit equals mainline commit -> clean")
    func identicalCommit() async throws {
        let fixture = GitFixture(name: "prov-identical-commit-7")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "file.swift", content: "v1", message: "v1")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(repository: repo, paths: ["file.swift"], recordedCommit: c1)

        #expect(result.verdict == .clean)
        #expect(result.isStillGood == true)
        #expect(result.isDiverged == false)
    }

    @Test("No mutation invariant: status, refs, HEAD, file contents unchanged after provenance diff test")
    func noMutationInvariant() async throws {
        let fixture = GitFixture(name: "prov-no-mutation-8")
        fixture.initRepo(defaultBranch: "main")

        let c1 = try fixture.commit(filename: "tracked.txt", content: "initial-tracked", message: "c1")
        _ = try fixture.commit(filename: "tracked.txt", content: "modified-mainline", message: "c2")

        let untrackedURL = fixture.url.appending(component: "untracked.txt")
        try "untracked content".write(to: untrackedURL, atomically: true, encoding: .utf8)

        let stagedURL = fixture.url.appending(component: "staged.txt")
        try "staged content".write(to: stagedURL, atomically: true, encoding: .utf8)
        _ = fixture.run(["add", "staged.txt"])

        let trackedURL = fixture.url.appending(component: "tracked.txt")
        try "dirty working tree modification".write(to: trackedURL, atomically: true, encoding: .utf8)

        let statusBefore = fixture.run(["status", "--porcelain"]).stdout
        let headBefore = fixture.revParse("HEAD")
        let symHeadBefore = fixture.run(["symbolic-ref", "HEAD"]).stdout
        let trackedBefore = try String(contentsOf: trackedURL, encoding: .utf8)
        let untrackedBefore = try String(contentsOf: untrackedURL, encoding: .utf8)
        let stagedBefore = try String(contentsOf: stagedURL, encoding: .utf8)

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()

        _ = await tester.testProvenance(repository: repo, paths: ["tracked.txt"], recordedCommit: c1)

        let statusAfter = fixture.run(["status", "--porcelain"]).stdout
        let headAfter = fixture.revParse("HEAD")
        let symHeadAfter = fixture.run(["symbolic-ref", "HEAD"]).stdout
        let trackedAfter = try String(contentsOf: trackedURL, encoding: .utf8)
        let untrackedAfter = try String(contentsOf: untrackedURL, encoding: .utf8)
        let stagedAfter = try String(contentsOf: stagedURL, encoding: .utf8)

        #expect(statusAfter == statusBefore)
        #expect(headAfter == headBefore)
        #expect(symHeadAfter == symHeadBefore)
        #expect(trackedAfter == trackedBefore)
        #expect(untrackedAfter == untrackedBefore)
        #expect(stagedAfter == stagedBefore)
    }
}
