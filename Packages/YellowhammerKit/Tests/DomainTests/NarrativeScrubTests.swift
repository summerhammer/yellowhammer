import Domain
import Foundation
import Testing

@Suite("NarrativeScrub")
struct NarrativeScrubTests {
    @Test("a credential is replaced wherever it sits, with no surrounding whitespace needed")
    func replacesEmbeddedCredential() {
        let scrub = NarrativeScrub(credentials: ["abc123xyz"])
        #expect(scrub.apply("Authorization: Bearer abc123xyz") == "Authorization: Bearer <redacted>")
        #expect(scrub.apply("GET /x?token=abc123xyz&a=1") == "GET /x?token=<redacted>&a=1")
        #expect(scrub.apply(#"{"t":"abc123xyz"}"#) == #"{"t":"<redacted>"}"#)
    }

    @Test("the longest credential wins when one contains another")
    func longestFirst() {
        let scrub = NarrativeScrub(credentials: ["abc", "abcdef"])
        #expect(scrub.apply("value abcdef end") == "value <redacted> end")
    }

    @Test("an empty credential is ignored")
    func ignoresEmptyCredential() {
        #expect(NarrativeScrub(credentials: [""]).apply("plain text") == "plain text")
    }

    @Test("quoted Check output has its token, home paths and environment values handled")
    func quotedCheckOutput() {
        let scrub = NarrativeScrub(
            credentials: ["tok123abc"],
            homeDirectory: "/Users/alice",
            repositoryRoots: ["/Users/alice/dev/app"]
        )
        let input = """
        request failed with Bearer tok123abc
        /Users/alice/dev/app/Sources/A.swift:12: error
        (see /Users/alice/notes/x) for more
        HOME=/Users/alice
        GITHUB_TOKEN=tok123abc
        export FOO=bar
        """
        let expected = """
        request failed with Bearer <redacted>
        Sources/A.swift:12: error
        (see ~/notes/x) for more
        HOME=<redacted>
        GITHUB_TOKEN=<redacted>
        export FOO=<redacted>
        """
        #expect(scrub.apply(input) == expected)
    }

    @Test("the longest repository root wins, and the root itself becomes a dot")
    func longestRootWins() {
        let scrub = NarrativeScrub(
            homeDirectory: "/Users/alice",
            repositoryRoots: ["/Users/alice/dev", "/Users/alice/dev/app/"]
        )
        #expect(scrub.apply("/Users/alice/dev/app/Sources/A.swift") == "Sources/A.swift")
        #expect(scrub.apply("in /Users/alice/dev/app now") == "in . now")
        #expect(scrub.apply("/Users/alice/dev/other/B.swift") == "other/B.swift")
    }

    @Test("a path inside a git worktree becomes relative to the worktree")
    func gitAncestorDiscovery() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("narrative-scrub-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let worktree = home + "/orca/workspaces/app/wt1"
        try FileManager.default.createDirectory(atPath: worktree + "/Sources", withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)

        let scrub = NarrativeScrub(homeDirectory: home)
        #expect(scrub.apply("\(worktree)/Sources/A.swift:3: boom") == "Sources/A.swift:3: boom")
        #expect(scrub.apply("at \(worktree)") == "at .")
        #expect(scrub.apply("\(home)/orca/other.txt") == "~/orca/other.txt")
    }

    @Test("only a path boundary matches the home directory")
    func homeBoundary() {
        let scrub = NarrativeScrub(homeDirectory: "/Users/alice")
        #expect(scrub.apply("/Users/alice2/x") == "/Users/alice2/x")
        #expect(scrub.apply("cd /Users/alice") == "cd ~")
        #expect(scrub.apply("file:///Users/alice/x") == "file://~/x")
        #expect(scrub.apply("/Volumes/Users/alice/x") == "/Volumes/Users/alice/x")
    }

    @Test("lowercase and mid-line assignments are not environment values")
    func environmentShapeOnly() {
        let scrub = NarrativeScrub.none
        #expect(scrub.apply("attempts=3") == "attempts=3")
        #expect(NarrativeScrub(credentials: ["zzz"]).apply("see FOO=bar here") == "see FOO=bar here")
        #expect(NarrativeScrub(credentials: ["zzz"]).apply("  AWS_SECRET=abc") == "  AWS_SECRET=<redacted>")
        #expect(NarrativeScrub(credentials: ["zzz"]).apply(#"export FOO="x y""#) == "export FOO=<redacted>")
    }

    @Test("no home directory means no path trimming, and none changes nothing")
    func noneIsIdentity() {
        let text = "/Users/alice/x with Bearer abc"
        #expect(NarrativeScrub.none.apply(text) == text)
        #expect(NarrativeScrub(credentials: ["abc"]).apply(text) == "/Users/alice/x with Bearer <redacted>")
    }
}
