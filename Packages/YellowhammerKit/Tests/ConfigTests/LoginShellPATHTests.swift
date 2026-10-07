import Config
import Foundation
import Testing

@Suite("Reading the login-shell PATH")
struct LoginShellPATHTests {
    private let marker = "YH-MARK"

    @Test("parse ignores noise around the markers")
    func parseNoise() {
        let output = "Last login: today\nrc says hi\(marker)/a b/bin:/usr/bin\(marker)\nbye\n"
        #expect(LoginShellPATH.parse(output: output, marker: marker) == "/a b/bin:/usr/bin")
    }

    @Test("parse strips ANSI escape sequences")
    func parseANSI() {
        let output = "\u{1B}[1m\u{1B}[32m\(marker)\u{1B}[0m/usr/bin\u{1B}]0;title\u{07}\(marker)"
        #expect(LoginShellPATH.parse(output: output, marker: marker) == "/usr/bin")
    }

    @Test("parse is nil when a marker is missing or the PATH is empty")
    func parseMissing() {
        #expect(LoginShellPATH.parse(output: "noise", marker: marker) == nil)
        #expect(LoginShellPATH.parse(output: "\(marker)/usr/bin", marker: marker) == nil)
        #expect(LoginShellPATH.parse(output: "\(marker)  \n\(marker)", marker: marker) == nil)
    }

    @Test("arguments follow the shell")
    func shellArguments() {
        #expect(LoginShellPATH.arguments(shell: "/bin/zsh", command: "c") == ["-l", "-i", "-c", "c"])
        #expect(LoginShellPATH.arguments(shell: "/opt/homebrew/bin/fish", command: "c") == ["-l", "-c", "c"])
        #expect(LoginShellPATH.arguments(shell: "/bin/tcsh", command: "c") == ["-c", "c"])
    }

    @Test("fish joins its PATH list with colons; other shells print $PATH as it is")
    func shellCommand() {
        #expect(LoginShellPATH.command(marker: "M", shell: "/bin/zsh")
            == "printf '%s' 'M'; printf '%s' \"$PATH\"; printf '%s' 'M'")
        #expect(LoginShellPATH.command(marker: "M", shell: "/opt/homebrew/bin/fish")
            == "printf '%s' 'M'; string join ':' $PATH; printf '%s' 'M'")
    }

    @Test("the operator's shell is an absolute executable path")
    func operatorShell() {
        let shell = LoginShellPATH.operatorShell()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }

    @Test("read returns the PATH a fake shell prints after its rc noise")
    func readFakeShell() async throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let script = "#!/bin/sh\necho 'rc noise'\nfor last; do :; done\neval \"$last\"\necho trailing\n"
        let shell = try fixture.file("fake shell/sh", contents: script)
        let result = await LoginShellPATH.read(
            shell: shell, timeout: .seconds(20), environment: ["PATH": "/a b/bin:/usr/bin"]
        )
        #expect(result == .path("/a b/bin:/usr/bin"))
    }

    @Test("read kills a shell that does not finish and reports the timeout")
    func readTimeout() async throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let shell = try fixture.file("slow-sh", contents: "#!/bin/sh\nsleep 30\n")
        let started = ContinuousClock.now
        let result = await LoginShellPATH.read(
            shell: shell, timeout: .milliseconds(500), environment: ["PATH": "/bin:/usr/bin"]
        )
        #expect(result == .failed(.timedOut(.milliseconds(500))))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
