import Domain
import Foundation
import Repositories
import Testing

@Suite("Provenance transcription tests")
struct ProvenanceTranscriptionTests {

    @Test("Operator-supplied transcription block -> operatorSupplied, isStillGood == true, isDiverged == false")
    func operatorSuppliedBlock() async throws {
        let fixture = GitFixture(name: "prov-operator-supplied-1")
        await fixture.initRepo(defaultBranch: "main")
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()

        // 1. authorSupplied: true with commit
        let night = NightStart(rawValue: "2026-09-16")
        let block1 = TranscriptionBlock(
            repository: "app",
            paths: ["contract.swift"],
            mainlineCommit: "abc1234",
            content: "custom content",
            contentHash: "hash1",
            authorSupplied: true,
            authorSuppliedNight: night
        )
        let result1 = await tester.testTranscriptionBlock(block1, in: repo)
        #expect(result1.verdict == .operatorSupplied)
        #expect(result1.isStillGood == true)
        #expect(result1.isDiverged == false)
        #expect(result1.changedPaths == [])

        // 2. authorSupplied: false with nil commit
        let block2 = TranscriptionBlock(
            repository: "app",
            paths: ["contract.swift"],
            mainlineCommit: nil,
            content: "custom content",
            contentHash: "hash2",
            authorSupplied: false
        )
        let result2 = await tester.testTranscriptionBlock(block2, in: repo)
        #expect(result2.verdict == .operatorSupplied)
        #expect(result2.isStillGood == true)
        #expect(result2.isDiverged == false)

        // 3. authorSupplied: false with empty commit
        let block3 = TranscriptionBlock(
            repository: "app",
            paths: ["contract.swift"],
            mainlineCommit: "",
            content: "custom content",
            contentHash: "hash3",
            authorSupplied: false
        )
        let result3 = await tester.testTranscriptionBlock(block3, in: repo)
        #expect(result3.verdict == .operatorSupplied)
        #expect(result3.isStillGood == true)
        #expect(result3.isDiverged == false)
    }

    @Test("Pinned ResolvedMainlines / ResolvedMainline is honoured")
    func pinnedMainlineHonoured() async throws {
        let fixture = GitFixture(name: "prov-pinned-mainline-2")
        await fixture.initRepo(defaultBranch: "main")

        let c1 = try await fixture.commit(filename: "contract.swift", content: "protocol Contract {}", message: "v1")
        _ = try await fixture.commit(
            filename: "contract.swift", content: "protocol Contract modified {}", message: "v2"
        )

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()

        let pinned = ResolvedMainline(
            repository: "app",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: c1
        )
        let result = await tester.testProvenance(
            repository: repo,
            paths: ["contract.swift"],
            recordedCommit: c1,
            mainline: pinned
        )

        #expect(result.verdict == .clean)
        #expect(result.mainlineCommit == c1)
        #expect(result.isStillGood == true)

        let projectRepos = ProjectRepositories(workingRepos: [repo])
        let mainlines = ResolvedMainlines(workingRepos: ["app": pinned])
        let block = TranscriptionBlock(
            repository: "app",
            paths: ["contract.swift"],
            mainlineCommit: c1,
            content: "c",
            contentHash: "h",
            authorSupplied: false
        )
        let blockResult = await tester.testTranscriptionBlock(
            block,
            projectRepositories: projectRepos,
            mainlines: mainlines
        )
        #expect(blockResult.verdict == .clean)
        #expect(blockResult.mainlineCommit == c1)
    }

    @Test("SpecSource provenance check")
    func specSourceProvenanceCheck() async throws {
        let fixture = GitFixture(name: "prov-specsource-3")
        await fixture.initRepo(defaultBranch: "main")

        let c1 = try await fixture.commit(filename: "spec.md", content: "# Spec v1", message: "v1")
        _ = try await fixture.commit(filename: "spec.md", content: "# Spec v2", message: "v2")

        let specSource = SpecSource(path: fixture.path)
        let tester = ProvenanceDiffTester()

        let directResult = await tester.testProvenance(
            specSource: specSource,
            paths: ["spec.md"],
            recordedCommit: c1
        )
        #expect(directResult.verdict == .stale(changedPaths: ["spec.md"]))
        #expect(directResult.isDiverged == true)

        let blockSpecSource = TranscriptionBlock(
            repository: "spec_source",
            paths: ["spec.md"],
            mainlineCommit: c1,
            content: "# Spec v1",
            contentHash: "h1",
            authorSupplied: false
        )
        let projectRepos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let blockResult1 = await tester.testTranscriptionBlock(
            blockSpecSource,
            projectRepositories: projectRepos
        )
        #expect(blockResult1.verdict == .stale(changedPaths: ["spec.md"]))
        #expect(blockResult1.repository == "spec_source")

        let blockSpec = TranscriptionBlock(
            repository: "spec",
            paths: ["spec.md"],
            mainlineCommit: c1,
            content: "# Spec v1",
            contentHash: "h2",
            authorSupplied: false
        )
        let blockResult2 = await tester.testTranscriptionBlock(
            blockSpec,
            projectRepositories: projectRepos
        )
        #expect(blockResult2.verdict == .stale(changedPaths: ["spec.md"]))
        #expect(blockResult2.repository == "spec")
    }

    @Test("Missing repository directory -> untestable")
    func missingRepositoryDirectory() async {
        let repo = Repo(name: "missing", path: "/tmp/nonexistent-\(UUID().uuidString)", role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(
            repository: repo,
            paths: ["file.swift"],
            recordedCommit: "abc"
        )

        if case .untestable(let reason) = result.verdict {
            #expect(reason.contains("does not exist"))
        } else {
            Issue.record("Expected untestable verdict, got \(result.verdict)")
        }
        #expect(result.isStillGood == false)
        #expect(result.isDiverged == false)

        let spec = SpecSource(path: "/tmp/nonexistent-spec-\(UUID().uuidString)")
        let specResult = await tester.testProvenance(
            specSource: spec,
            paths: ["spec.md"],
            recordedCommit: "abc"
        )
        if case .untestable(let reason) = specResult.verdict {
            #expect(reason.contains("does not exist"))
        } else {
            Issue.record("Expected untestable verdict, got \(specResult.verdict)")
        }
    }

    @Test("Unresolvable commit -> untestable")
    func unresolvableCommit() async throws {
        let fixture = GitFixture(name: "prov-bad-commit-4")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "file.swift", content: "v1", message: "v1")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = ProvenanceDiffTester()
        let result = await tester.testProvenance(
            repository: repo,
            paths: ["file.swift"],
            recordedCommit: "0000000000000000000000000000000000000000"
        )

        if case .untestable(let reason) = result.verdict {
            #expect(reason.contains("could not resolve recorded commit"))
        } else {
            Issue.record("Expected untestable verdict, got \(result.verdict)")
        }
    }

    @Test("Unconfigured repository in ProjectRepositories -> untestable")
    func unconfiguredRepository() async throws {
        let fixture = GitFixture(name: "prov-unconfigured-5")
        await fixture.initRepo(defaultBranch: "main")
        let repo = Repo(name: "app", path: fixture.path, role: .backend)

        let block = TranscriptionBlock(
            repository: "unknown_repo",
            paths: ["contract.swift"],
            mainlineCommit: "abc1234",
            content: "content",
            contentHash: "hash",
            authorSupplied: false
        )

        let projectRepos = ProjectRepositories(workingRepos: [repo])
        let tester = ProvenanceDiffTester()
        let result = await tester.testTranscriptionBlock(block, projectRepositories: projectRepos)

        #expect(result.verdict == .untestable(reason: "repository unknown_repo is not configured in this Project"))
        #expect(result.isStillGood == false)
        #expect(result.isDiverged == false)
    }
}

@Suite("Provenance report roll-up tests")
struct ProvenanceReportRollUpTests {

    @Test("Multi-transcription / multi-repo CardProvenanceReport roll-up with divergence")
    func multiTranscriptionRollUpWithDivergence() async throws {
        let fixtureApp = GitFixture(name: "prov-rollup-app-6")
        await fixtureApp.initRepo(defaultBranch: "main")
        let appC1 = try await fixtureApp.commit(filename: "app.swift", content: "v1", message: "v1")
        _ = try await fixtureApp.commit(filename: "app.swift", content: "v2", message: "v2")

        let fixtureBackend = GitFixture(name: "prov-rollup-backend-6")
        await fixtureBackend.initRepo(defaultBranch: "main")
        let backendC1 = try await fixtureBackend.commit(filename: "api.swift", content: "v1", message: "v1")
        _ = try await fixtureBackend.commit(filename: "other.swift", content: "other", message: "other")

        let fixtureSpec = GitFixture(name: "prov-rollup-spec-6")
        await fixtureSpec.initRepo(defaultBranch: "main")
        let specC1 = try await fixtureSpec.commit(filename: "spec.md", content: "spec v1", message: "spec v1")
        _ = try await fixtureSpec.commit(filename: "spec.md", content: "spec v2", message: "spec v2")

        let projectRepos = ProjectRepositories(
            workingRepos: [
                Repo(name: "app", path: fixtureApp.path, role: .mobile),
                Repo(name: "backend", path: fixtureBackend.path, role: .backend)
            ],
            specSource: SpecSource(path: fixtureSpec.path)
        )

        let b1 = TranscriptionBlock(
            repository: "app", paths: ["app.swift"], mainlineCommit: appC1,
            content: "a", contentHash: "h1", authorSupplied: false
        )
        let b2 = TranscriptionBlock(
            repository: "backend", paths: ["api.swift"], mainlineCommit: backendC1,
            content: "b", contentHash: "h2", authorSupplied: false
        )
        let b3 = TranscriptionBlock(
            repository: "spec_source", paths: ["spec.md"], mainlineCommit: specC1,
            content: "s", contentHash: "h3", authorSupplied: false
        )
        let b4 = TranscriptionBlock(
            repository: "app", paths: ["custom.swift"], mainlineCommit: "abc",
            content: "c", contentHash: "h4", authorSupplied: true
        )
        let brief = ArchitecturalBrief(prose: "Approach", transcriptions: [b1, b2, b3, b4])

        let tester = ProvenanceDiffTester()
        let report = await tester.evaluateBrief(brief, projectRepositories: projectRepos)

        #expect(report.results.count == 4)
        #expect(report.isAllClean == false)
        #expect(report.hasDivergence == true)
        #expect(report.divergedRepositories == ["app", "spec_source"])
        #expect(report.allChangedPaths == ["app.swift", "spec.md"])
        #expect(report["app"]?.isDiverged == true)
        #expect(report["backend"]?.verdict == ProvenanceVerdict.clean)
        #expect(report["spec_source"]?.isDiverged == true)
    }

    @Test("Multi-transcription / multi-repo CardProvenanceReport roll-up all clean")
    func multiTranscriptionRollUpAllClean() async throws {
        let fixtureBackend = GitFixture(name: "prov-rollup-clean-backend-6")
        await fixtureBackend.initRepo(defaultBranch: "main")
        let backendC1 = try await fixtureBackend.commit(filename: "api.swift", content: "v1", message: "v1")

        let projectRepos = ProjectRepositories(
            workingRepos: [Repo(name: "backend", path: fixtureBackend.path, role: .backend)]
        )

        let blockBackend = TranscriptionBlock(
            repository: "backend",
            paths: ["api.swift"],
            mainlineCommit: backendC1,
            content: "backend",
            contentHash: "h2",
            authorSupplied: false
        )
        let cleanBrief = ArchitecturalBrief(prose: "Clean approach", transcriptions: [blockBackend])
        let tester = ProvenanceDiffTester()
        let cleanReport = await tester.evaluateBrief(cleanBrief, projectRepositories: projectRepos)

        #expect(cleanReport.isAllClean == true)
        #expect(cleanReport.hasDivergence == false)
        #expect(cleanReport.divergedRepositories == [])
        #expect(cleanReport.allChangedPaths == [])
    }
}
