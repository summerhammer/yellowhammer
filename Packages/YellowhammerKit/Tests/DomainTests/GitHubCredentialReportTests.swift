import Domain
import Foundation
import Testing

@Suite("GitHubCredentialReport, the GitHub credential check's one-line result")
struct GitHubCredentialReportTests {
    private static func repo(_ status: GitHubCredentialReport.RepoStatus) -> GitHubCredentialReport.Repo {
        GitHubCredentialReport.Repo(
            name: "backend", path: "~/dev/backend", slug: "acme/backend", status: status, message: "m"
        )
    }

    private static func report(
        _ state: GitHubCredentialReport.State = .resolves, repos: [GitHubCredentialReport.Repo] = []
    ) -> GitHubCredentialReport {
        GitHubCredentialReport(reference: "keychain:github", state: state, login: "octocat", message: "m", repos: repos)
    }

    @Test("The raw values are the camelCase contract with the app")
    func rawValues() {
        #expect(GitHubCredentialReport.State.allCasesForTest.map(\.rawValue)
            == ["resolves", "missing", "unreadable", "rejected", "unreachable"])
        #expect(GitHubCredentialReport.RepoStatus.allCasesForTest.map(\.rawValue) == [
            "ok", "okUnverified", "noPushPermission", "missingScope", "notFound", "notGitHub", "unreachable",
            "rejected"
        ])
    }

    @Test("A report encodes as one compact line with sorted keys")
    func encodes() {
        let report = GitHubCredentialReport(
            reference: "keychain:github", state: .resolves, login: "octocat", message: "ok",
            repos: [GitHubCredentialReport.Repo(
                name: "backend", path: "/p", slug: "acme/backend", status: .okUnverified, message: "fine"
            )]
        )
        #expect(report.encodeLine() == """
            {"login":"octocat","message":"ok","reference":"keychain:github",\
            "repos":[{"message":"fine","name":"backend","path":"\\/p","slug":"acme\\/backend",\
            "status":"okUnverified"}],"state":"resolves"}
            """)
    }

    @Test("Optional fields are omitted when nil")
    func omitsNil() {
        let report = GitHubCredentialReport(reference: "keychain:github", state: .missing, message: "m")
        #expect(report.encodeLine()
            == #"{"message":"m","reference":"keychain:github","repos":[],"state":"missing"}"#)
    }

    @Test("decodeLastLine round-trips and reads the last non-blank line")
    func roundTrips() {
        let report = Self.report(repos: [Self.repo(.ok), Self.repo(.notFound)])
        #expect(GitHubCredentialReport.decodeLastLine(["progress noise", report.encodeLine(), "  ", ""]) == report)
    }

    @Test("decodeLastLine is nil without a report line")
    func decodeNil() {
        #expect(GitHubCredentialReport.decodeLastLine([]) == nil)
        #expect(GitHubCredentialReport.decodeLastLine(["", "  "]) == nil)
        #expect(GitHubCredentialReport.decodeLastLine(["not json"]) == nil)
        #expect(GitHubCredentialReport.decodeLastLine(["[]"]) == nil)
    }

    @Test("A report is valid when it resolves and every Repo is ok or okUnverified")
    func valid() {
        #expect(Self.report(repos: []).isValid)
        #expect(Self.report(repos: [Self.repo(.ok), Self.repo(.okUnverified)]).isValid)
    }

    @Test("A report is not valid when a Repo cannot push")
    func invalidRepo() {
        for status: GitHubCredentialReport.RepoStatus in [
            .noPushPermission, .missingScope, .notFound, .notGitHub, .unreachable, .rejected
        ] {
            #expect(!Self.report(repos: [Self.repo(.ok), Self.repo(status)]).isValid, "\(status)")
        }
    }

    @Test("A report is not valid unless the credential resolves")
    func invalidState() {
        for state: GitHubCredentialReport.State in [.missing, .unreadable, .rejected, .unreachable] {
            #expect(!Self.report(state, repos: [Self.repo(.ok)]).isValid, "\(state)")
        }
    }
}

private extension GitHubCredentialReport.State {
    static let allCasesForTest: [Self] = [.resolves, .missing, .unreadable, .rejected, .unreachable]
}

private extension GitHubCredentialReport.RepoStatus {
    static let allCasesForTest: [Self] = [
        .ok, .okUnverified, .noPushPermission, .missingScope, .notFound, .notGitHub, .unreachable, .rejected
    ]
}
