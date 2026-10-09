import Domain
import Foundation
import Repositories
import Testing

@Suite("SpecCitationResolution tests")
struct SpecCitationResolutionTests {

    private func populateSpecFixture(_ fixture: borrowing GitFixture) async throws -> String {
        let storyContent = """
        # Author an Architectural Brief

        ## Story: Brief authoring
        As Yellowhammer I want an architectural brief...
        """
        _ = try await fixture.commit(
            filename: "docs/requirements/epics/feature-authoring/stories/author-an-architectural-brief.md",
            content: storyContent,
            message: "add story"
        )

        let goalsContent = """
        # Business Goals

        ## G1: An Idle Night Becomes Shipped Work {#g1-an-idle-night-becomes-shipped-work}
        Target: Go to bed with a specification...

        ## G2: The Morning Is Triage, Not Archaeology {#g2-the-morning-is-triage-not-archaeology}
        Target: Zero terminals opened...

        ## G5: Five Is Alive {#g5-five}
        Target: Maintain high quality...
        """
        _ = try await fixture.commit(
            filename: "docs/requirements/vision/goals.md",
            content: goalsContent,
            message: "add goals"
        )

        _ = try await fixture.commit(
            filename: "path.md",
            content: "# Root spec path\n",
            message: "add path.md"
        )

        _ = try await fixture.commit(
            filename: "docs/requirements/epics/live-check/overview.md",
            content: "# Live Check Overview\n\n## Business Rules\nRules here.\n",
            message: "add overview"
        )

        return try await fixture.commit(
            filename: "docs/requirements/epics/live-check/stories/greeting.md",
            content: "# Greeting Story\n\n## Acceptance Criteria\nCriteria here.\n",
            message: "add greeting story"
        )
    }

    @Test("Resolves citations given as path.md#anchor and plain repository paths")
    func repositoryPathResolution() async throws {
        let fixture = GitFixture(name: "spec-citation-paths")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        // 1. path.md#anchor (top-level path with anchor)
        let resPathAnchor = await reader.resolveCitation("path.md#anchor", in: repos)
        #expect(resPathAnchor.resolves == true)
        #expect(resPathAnchor.resolvedPath == "path.md")
        #expect(resPathAnchor.commit == sha)
        #expect(resPathAnchor.repository == "spec_source")
        #expect(resPathAnchor.failureReason == nil)

        // 2. plain path (top-level and nested repository path without anchor)
        let resPlainPath = await reader.resolveCitation("path.md", in: repos)
        #expect(resPlainPath.resolves == true)
        #expect(resPlainPath.resolvedPath == "path.md")

        let resNestedPlainPath = await reader.resolveCitation(
            "docs/requirements/epics/live-check/overview.md",
            in: repos
        )
        #expect(resNestedPlainPath.resolves == true)
        #expect(resNestedPlainPath.resolvedPath == "docs/requirements/epics/live-check/overview.md")

        // 3. full repository path with anchor (issue #406 citations)
        let resGreetingAnchor = await reader.resolveCitation(
            "docs/requirements/epics/live-check/stories/greeting.md#acceptance-criteria",
            in: repos
        )
        #expect(resGreetingAnchor.resolves == true)
        #expect(resGreetingAnchor.resolvedPath == "docs/requirements/epics/live-check/stories/greeting.md")

        let resOverviewAnchor = await reader.resolveCitation(
            "docs/requirements/epics/live-check/overview.md#business-rules",
            in: repos
        )
        #expect(resOverviewAnchor.resolves == true)
        #expect(resOverviewAnchor.resolvedPath == "docs/requirements/epics/live-check/overview.md")

        // 4. Nonexistent path rejection
        let resMissing = await reader.resolveCitation("nonexistent.md#anchor", in: repos)
        #expect(resMissing.resolves == false)
        #expect(resMissing.failureReason?.contains("could not be resolved") == true)
    }

    @Test("Resolves citations given as <epic>/<story> and goal ID")
    func identifierResolution() async throws {
        let fixture = GitFixture(name: "spec-citation-ids")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        // 1. <epic>/<story> and <epic>/<story>#anchor
        let resStoryID = await reader.resolveCitation(
            "feature-authoring/author-an-architectural-brief",
            in: repos
        )
        #expect(resStoryID.resolves == true)
        #expect(
            resStoryID.resolvedPath ==
            "docs/requirements/epics/feature-authoring/stories/author-an-architectural-brief.md"
        )

        let resStoryAnchor = await reader.resolveCitation(
            "feature-authoring/author-an-architectural-brief#brief-authoring",
            in: repos
        )
        #expect(resStoryAnchor.resolves == true)
        #expect(
            resStoryAnchor.resolvedPath ==
            "docs/requirements/epics/feature-authoring/stories/author-an-architectural-brief.md"
        )

        // 2. goal ID
        let resGoalID = await reader.resolveCitation("G1", in: repos)
        #expect(resGoalID.resolves == true)
        #expect(resGoalID.resolvedPath == "docs/requirements/vision/goals.md")
    }

    @Test("Resolves valid story ID `<epic>/<story>`")
    func validStoryIDResolution() async throws {
        let fixture = GitFixture(name: "spec-story-valid")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        let resolution = await reader.resolveCitation(
            "feature-authoring/author-an-architectural-brief",
            in: repos
        )

        #expect(resolution.resolves == true)
        #expect(
            resolution.resolvedPath ==
            "docs/requirements/epics/feature-authoring/stories/author-an-architectural-brief.md"
        )
        #expect(resolution.commit == sha)
        #expect(resolution.repository == "spec_source")
        #expect(resolution.failureReason == nil)

        let predicate = await reader.resolvesCitation(
            "feature-authoring/author-an-architectural-brief",
            in: repos
        )
        #expect(predicate == true)
    }

    @Test("Rejects missing story ID with clear reason")
    func missingStoryIDRejection() async throws {
        let fixture = GitFixture(name: "spec-story-missing")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        let resolution = await reader.resolveCitation(
            "feature-authoring/nonexistent-story",
            in: repos
        )

        #expect(resolution.resolves == false)
        #expect(resolution.resolvedPath == nil)
        #expect(resolution.commit == sha)
        #expect(resolution.repository == "spec_source")
        #expect(resolution.failureReason?.contains("could not be resolved") == true)

        let predicate = await reader.resolvesCitation(
            "feature-authoring/nonexistent-story",
            in: repos
        )
        #expect(predicate == false)
    }

    @Test("Resolves valid goal IDs (G1, G5, anchors, and slugs)")
    func validGoalIDResolution() async throws {
        let fixture = GitFixture(name: "spec-goals-valid")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        // 1. G1
        let resG1 = await reader.resolveCitation("G1", in: repos)
        #expect(resG1.resolves == true)
        #expect(resG1.resolvedPath == "docs/requirements/vision/goals.md")
        #expect(resG1.commit == sha)

        // 2. g1 (case-insensitive)
        let resLowerG1 = await reader.resolveCitation("g1", in: repos)
        #expect(resLowerG1.resolves == true)

        // 3. G5
        let resG5 = await reader.resolveCitation("G5", in: repos)
        #expect(resG5.resolves == true)

        // 4. Anchor format: {#...}
        let resAnchor = await reader.resolveCitation(
            "{#g1-an-idle-night-becomes-shipped-work}",
            in: repos
        )
        #expect(resAnchor.resolves == true)
        #expect(resAnchor.resolvedPath == "docs/requirements/vision/goals.md")

        // 5. Slug format without braces
        let resSlug = await reader.resolveCitation(
            "g1-an-idle-night-becomes-shipped-work",
            in: repos
        )
        #expect(resSlug.resolves == true)

        // 6. Path with anchor
        let resPathAnchor = await reader.resolveCitation(
            "docs/requirements/vision/goals.md#g2-the-morning-is-triage-not-archaeology",
            in: repos
        )
        #expect(resPathAnchor.resolves == true)
    }

    @Test("Rejects missing goal ID with clear reason")
    func missingGoalIDRejection() async throws {
        let fixture = GitFixture(name: "spec-goals-missing")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await populateSpecFixture(fixture)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        let resolution = await reader.resolveCitation("G99", in: repos)
        #expect(resolution.resolves == false)
        #expect(resolution.failureReason?.contains("could not be resolved") == true)

        let predicate = await reader.resolvesCitation("G99", in: repos)
        #expect(predicate == false)
    }

    @Test("Validates single specification source rule across both kinds (0 and >1 sources)")
    func singleSpecificationSourceValidation() async throws {
        let fixture = GitFixture(name: "spec-single-source")
        await fixture.initRepo(defaultBranch: "main")

        let reader = MainlineReader()

        // 1. Zero specification sources
        let noSpecRepos = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: fixture.path, role: .backend)
        ])
        #expect(noSpecRepos.specificationSourceLookup == .none)
        #expect(noSpecRepos.specificationSource == nil)
        #expect(throws: MainlineReadError.noSpecificationSource) {
            try reader.validateSpecificationSource(in: noSpecRepos)
        }

        // 2. Two specification sources: specSource AND working repo with role == .spec
        let specSource = SpecSource(path: fixture.path)
        let specRepo = Repo(name: "spec-repo", path: fixture.path, role: .spec)
        let twoSourcesRepos = ProjectRepositories(
            workingRepos: [specRepo],
            specSource: specSource
        )
        #expect(throws: MainlineReadError.multipleSpecificationSources(["spec_source", "spec-repo"])) {
            try reader.validateSpecificationSource(in: twoSourcesRepos)
        }

        // 3. Two working repos both having role == .spec
        let specRepo2 = Repo(name: "spec-repo-2", path: fixture.path, role: .spec)
        let twoWorkingSpecsRepos = ProjectRepositories(
            workingRepos: [specRepo, specRepo2],
            specSource: nil
        )
        #expect(throws: MainlineReadError.multipleSpecificationSources(["spec-repo", "spec-repo-2"])) {
            try reader.validateSpecificationSource(in: twoWorkingSpecsRepos)
        }

        // 4. Exactly one source via specSource
        let validSpecSourceRepos = ProjectRepositories(
            workingRepos: [Repo(name: "app", path: fixture.path, role: .backend)],
            specSource: specSource
        )
        let source1 = try reader.validateSpecificationSource(in: validSpecSourceRepos)
        #expect(source1 == .specSource(specSource))
        #expect(source1.repositoryName == "spec_source")
        #expect(validSpecSourceRepos.specificationSource == .specSource(specSource))

        // 5. Exactly one source via working repo with role == .spec
        let validWorkingSpecRepos = ProjectRepositories(
            workingRepos: [
                specRepo,
                Repo(name: "app", path: fixture.path, role: .backend)
            ],
            specSource: nil
        )
        let source2 = try reader.validateSpecificationSource(in: validWorkingSpecRepos)
        #expect(source2 == .workingRepo(specRepo))
        #expect(source2.repositoryName == "spec-repo")
        #expect(validWorkingSpecRepos.specificationSource == .workingRepo(specRepo))
    }

    @Test("Rejects citation resolution when Project has 0 or >1 specification sources")
    func invalidSourceRejectionDuringCitationResolution() async throws {
        let fixture = GitFixture(name: "spec-invalid-resolve")
        await fixture.initRepo(defaultBranch: "main")
        let reader = MainlineReader()

        // Zero sources
        let noSpecRepos = ProjectRepositories(workingRepos: [])
        let resNone = await reader.resolveCitation("G1", in: noSpecRepos)
        #expect(resNone.resolves == false)
        #expect(resNone.failureReason?.contains("no specification source") == true)
        #expect(await reader.resolvesCitation("G1", in: noSpecRepos) == false)

        // Multiple sources
        let specSource = SpecSource(path: fixture.path)
        let specRepo = Repo(name: "my-spec", path: fixture.path, role: .spec)
        let multiRepos = ProjectRepositories(workingRepos: [specRepo], specSource: specSource)
        let resMulti = await reader.resolveCitation("G1", in: multiRepos)
        #expect(resMulti.resolves == false)
        #expect(resMulti.failureReason?.contains("multiple specification sources") == true)
        #expect(await reader.resolvesCitation("G1", in: multiRepos) == false)
    }
}

extension SpecCitationResolutionTests {
    @Test("Resolves citations against working repo having role == .spec")
    func workingRepoSpecCitationResolution() async throws {
        let fixture = GitFixture(name: "spec-working-repo-role")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await populateSpecFixture(fixture)

        let specRepo = Repo(name: "product-spec", path: fixture.path, role: .spec)
        let repos = ProjectRepositories(workingRepos: [specRepo], specSource: nil)
        let reader = MainlineReader()

        let resolution = await reader.resolveCitation(
            "feature-authoring/author-an-architectural-brief",
            in: repos
        )
        #expect(resolution.resolves == true)
        #expect(resolution.repository == "product-spec")
        #expect(resolution.commit == sha)
    }

    @Test("Commit-pinned citation resolution supports time-travel")
    func commitPinnedResolutionTimeTravel() async throws {
        let fixture = GitFixture(name: "spec-time-travel")
        await fixture.initRepo(defaultBranch: "main")

        // Commit 1: Story v1 exists
        let sha1 = try await fixture.commit(
            filename: "docs/requirements/epics/auth/stories/v1.md",
            content: "# V1 Story",
            message: "add v1 story"
        )

        // Commit 2: Delete v1 and add v2
        _ = await fixture.run(["rm", "docs/requirements/epics/auth/stories/v1.md"])
        let sha2 = try await fixture.commit(
            filename: "docs/requirements/epics/auth/stories/v2.md",
            content: "# V2 Story",
            message: "replace v1 with v2"
        )

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        // Pinned to Commit 1: v1 resolves, v2 does not
        let res1V1 = await reader.resolveCitation("auth/v1", in: repos, commit: sha1)
        #expect(res1V1.resolves == true)
        #expect(res1V1.commit == sha1)

        let res1V2 = await reader.resolveCitation("auth/v2", in: repos, commit: sha1)
        #expect(res1V2.resolves == false)

        // Pinned to Commit 2: v1 does not resolve, v2 resolves
        let res2V1 = await reader.resolveCitation("auth/v1", in: repos, commit: sha2)
        #expect(res2V1.resolves == false)

        let res2V2 = await reader.resolveCitation("auth/v2", in: repos, commit: sha2)
        #expect(res2V2.resolves == true)
        #expect(res2V2.commit == sha2)
    }

    @Test("Citation resolution leaves repository status, HEAD, and dirty files untouched")
    func noMutationInvariant() async throws {
        let fixture = GitFixture(name: "spec-no-mutation")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await populateSpecFixture(fixture)

        // Add dirty modifications in spec working tree
        let dirtyFileURL = fixture.url.appendingPathComponent("dirty-spec.txt")
        try "uncommitted work".write(to: dirtyFileURL, atomically: true, encoding: .utf8)

        let statusBefore = await fixture.run(["status", "--porcelain"]).stdout
        let headBefore = await fixture.run(["rev-parse", "HEAD"]).stdout
        let dirtyFileBefore = try String(contentsOf: dirtyFileURL, encoding: .utf8)

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        _ = await reader.resolveCitation("G1", in: repos)
        _ = await reader.resolveCitation("feature-authoring/author-an-architectural-brief", in: repos)
        _ = await reader.resolveCitation("nonexistent/story", in: repos)

        let statusAfter = await fixture.run(["status", "--porcelain"]).stdout
        let headAfter = await fixture.run(["rev-parse", "HEAD"]).stdout
        let dirtyFileAfter = try String(contentsOf: dirtyFileURL, encoding: .utf8)

        #expect(statusBefore == statusAfter)
        #expect(headBefore == headAfter)
        #expect(dirtyFileBefore == dirtyFileAfter)
    }
}
