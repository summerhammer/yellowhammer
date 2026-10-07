import Config
import Foundation
import Testing

@Suite("The executable search path")
struct ExecutableSearchPathTests {
    @Test("repeated directories keep their first occurrence, normalised")
    func dedup() {
        let path = ExecutableSearchPath.composed(
            loginShellPATH: "/h/.local/bin:/usr/bin//:/h/.local/bin/:/h/x/../.local/bin:/usr/bin",
            processPATH: "/usr/bin:/bin", systemPaths: ["/bin", "/sbin"], locations: [.absolute("/sbin/")],
            homeDirectory: "/h"
        )
        #expect(path.entries.map(\.directory) == ["/h/.local/bin", "/usr/bin", "/bin", "/sbin"])
        #expect(path.entries.map(\.source) == [.loginShell, .loginShell, .appProcess, .systemPaths])
    }

    @Test("~/ expands against home; empty, relative and fnm_multishells segments are dropped")
    func cleaning() {
        let path = ExecutableSearchPath.composed(
            loginShellPATH: "~/bin::rel/dir:./x:/tmp/fnm_multishells/123_456/bin:/ok",
            processPATH: nil, systemPaths: [], locations: [], homeDirectory: "/Users/me"
        )
        #expect(path.entries.map(\.directory) == ["/Users/me/bin", "/ok"])
    }

    @Test("system paths read /etc/paths then /etc/paths.d sorted by file name")
    func systemPaths() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.file("etc/paths", contents: "/usr/local/bin\n  /usr/bin  \n\n")
        try fixture.file("etc/paths.d/20-b", contents: "/b\n")
        try fixture.file("etc/paths.d/10-a", contents: "\n/a\n/a2\n")
        #expect(ExecutableSearchPath.systemPaths(etcDirectory: "\(fixture.root)/etc")
            == ["/usr/local/bin", "/usr/bin", "/a", "/a2", "/b"])
        #expect(ExecutableSearchPath.systemPaths(etcDirectory: "\(fixture.root)/none").isEmpty)
    }
}
