import Domain
import Foundation
import Repositories
import Testing

@Suite("Feature Branch push tests")
struct FeatureBranchPusherTests {

    @Test("A successful push lands the Feature Branch's tip on the remote")
    func successfulPush() async throws {
        let local = GitFixture(name: "push-success-local-1")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await local.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await local.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        let remote = GitFixture(name: "push-success-remote-1")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "app", path: local.path, role: .backend, defaultBranch: "main")
        let branch = FeatureBranch(name: "yh-project-feature")
        let pusher = FeatureBranchPusher()
        let outcome = await pusher.push(branch: branch, in: repo, mode: .real, credential: nil)

        guard case .pushed(let commit) = outcome else {
            Issue.record("expected .pushed, got \(outcome)")
            return
        }
        #expect(commit == featureSHA)
        await #expect(remote.revParse("refs/heads/yh-project-feature") == featureSHA)
    }

    @Test("Branch protection on the remote is reported and nothing else is attempted")
    func branchProtectionRejection() async throws {
        let local = GitFixture(name: "push-protected-local-2")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await local.run(["checkout", "-b", "yh-project-feature"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        let remote = GitFixture(name: "push-protected-remote-2")
        await remote.initRepo(bare: true, defaultBranch: "main")
        try remote.installHook(
            named: "pre-receive",
            script: """
            #!/bin/sh
            echo "GH006: Protected branch update failed" 1>&2
            exit 1
            """
        )
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "app", path: local.path, role: .backend, defaultBranch: "main")
        let branch = FeatureBranch(name: "yh-project-feature")
        let pusher = FeatureBranchPusher()
        let outcome = await pusher.push(branch: branch, in: repo, mode: .real, credential: nil)

        guard case .refusedByBranchProtection(let repository, _) = outcome else {
            Issue.record("expected .refusedByBranchProtection, got \(outcome)")
            return
        }
        #expect(repository == "app")
        await #expect(remote.revParse("refs/heads/yh-project-feature") == nil)
    }

    @Test("Rehearsal never pushes and runs no git command")
    func rehearsalNeverPushes() async throws {
        let local = GitFixture(name: "push-rehearsal-local-3")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await local.run(["checkout", "-b", "yh-project-feature"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        let remote = GitFixture(name: "push-rehearsal-remote-3")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "app", path: local.path, role: .backend, defaultBranch: "main")
        let branch = FeatureBranch(name: "yh-project-feature")
        let pusher = FeatureBranchPusher()
        let outcome = await pusher.push(branch: branch, in: repo, mode: .rehearsal, credential: nil)

        #expect(outcome == .notPushedInRehearsal)
        await #expect(remote.revParse("refs/heads/yh-project-feature") == nil)
    }

    @Test("Pushing the default branch itself is refused as a Mainline push and the remote is unchanged")
    func mainlinePushIsRefused() async throws {
        let local = GitFixture(name: "push-mainline-local-4")
        await local.initRepo(defaultBranch: "main")
        let mainSHA = try await local.commit(filename: "init.txt", content: "initial", message: "initial commit")

        let remote = GitFixture(name: "push-mainline-remote-4")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "app", path: local.path, role: .backend, defaultBranch: "main")
        let branch = FeatureBranch(name: "main")
        let pusher = FeatureBranchPusher()
        let outcome = await pusher.push(branch: branch, in: repo, mode: .real, credential: nil)

        #expect(outcome == .refusedMainline)
        await #expect(remote.revParse("refs/heads/main") == nil)
        _ = mainSHA
    }

    // MARK: - Failure classification

    @Test("Credential failure strings classify as credentials, not branch protection")
    func classifiesCredentialFailures() {
        let httpsAuthFailure = "remote: Support for password authentication was removed.\n" +
            "fatal: Authentication failed for 'https://github.com/org/repo.git/'"
        let forbidden = "remote: Permission to org/repo.git denied to user.\n" +
            "fatal: unable to access 'https://github.com/org/repo.git/': The requested URL returned error: 403"
        let sshPublicKey = "git@github.com: Permission denied (publickey).\n" +
            "fatal: Could not read from remote repository."
        let terminalPrompt = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"

        for stderr in [httpsAuthFailure, forbidden, sshPublicKey, terminalPrompt] {
            #expect(FeatureBranchPusher.classify(exitCode: 128, stderr: stderr) == .credentials)
        }
    }

    @Test("Branch-protection strings classify as branch protection")
    func classifiesBranchProtectionFailures() {
        let protectedBranch = "remote: error: GH006: Protected branch update failed for refs/heads/main.\n" +
            "! [remote rejected] main -> main (protected branch hook declined)"
        let preReceive = "remote: pre-receive hook declined\n" +
            "! [remote rejected] yh-a-b -> yh-a-b (pre-receive hook declined)"

        for stderr in [protectedBranch, preReceive] {
            #expect(FeatureBranchPusher.classify(exitCode: 1, stderr: stderr) == .branchProtection)
        }
    }

    @Test("An unrelated failure classifies as other")
    func classifiesUnrelatedFailures() {
        let networkFailure = "fatal: unable to access 'https://github.com/org/repo.git/': " +
            "Could not resolve host: github.com"
        #expect(FeatureBranchPusher.classify(exitCode: 128, stderr: networkFailure) == .other)
        #expect(FeatureBranchPusher.classify(exitCode: 0, stderr: networkFailure) == .other)
    }

    @Test("GitHubToken redacts its value from both descriptions")
    func gitHubTokenRedaction() {
        let token = GitHubToken("ghp_supersecretvalue")
        #expect(!token.description.contains("supersecretvalue"))
        #expect(!token.debugDescription.contains("supersecretvalue"))
        #expect(String(describing: token) == token.description)
    }
}
