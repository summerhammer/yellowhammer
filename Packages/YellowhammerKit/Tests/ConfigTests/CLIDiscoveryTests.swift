import Config
import Domain
import Foundation
import Testing

@Suite("Discovering agent CLIs")
struct CLIDiscoveryTests {
    private let finderPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    private func discover(
        _ fixture: CLIDiscoveryFixture, loginShellPATH: String? = nil, processPATH: String? = nil,
        descriptors: [AgentCLIDescriptor] = AgentCLIDescriptors.all
    ) -> [CLIDiscovery] {
        CLIDiscoverer.discover(environment: CLIDiscoveryEnvironment(
            homeDirectory: fixture.home, processPATH: processPATH, loginShellPATH: loginShellPATH,
            etcDirectory: "\(fixture.root)/etc", descriptors: descriptors,
            commonLocations: [.home(".local/bin"), .absolute("\(fixture.root)/opt/homebrew/bin")]
        ))
    }

    private func result(_ results: [CLIDiscovery], _ cli: String) throws -> CLIDiscovery {
        try #require(results.first { $0.descriptor.cli == cli })
    }

    @Test("each vendor descriptor finds its fixture")
    func findsEachVendor() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("home/.local/bin/claude")
        try fixture.binary("opt/homebrew/bin/codex")
        try fixture.binary("home/.local/bin/agy")
        let results = discover(fixture, processPATH: finderPATH)
        #expect(try result(results, "claude").preferred?.path == "\(fixture.home)/.local/bin/claude")
        #expect(try result(results, "codex").preferred?.path == "\(fixture.root)/opt/homebrew/bin/codex")
        #expect(try result(results, "agy").preferred?.path == "\(fixture.home)/.local/bin/agy")
    }

    @Test("a Finder-like PATH still finds ~/.local/bin/claude as a known location")
    func finderLikePATH() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("home/.local/bin/claude")
        let found = try result(discover(fixture, loginShellPATH: nil, processPATH: finderPATH), "claude")
        #expect(found.candidates.map(\.source) == [.knownLocation])
        #expect(found.preferred?.path == "\(fixture.home)/.local/bin/claude")
    }

    @Test("the login-shell PATH wins over the process PATH and the common locations")
    func precedence() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("login/claude")
        try fixture.binary("proc/claude")
        try fixture.binary("etc-bin/claude")
        try fixture.binary("home/.local/bin/claude")
        try fixture.file("etc/paths", contents: "\(fixture.root)/etc-bin\n")
        let found = try result(
            discover(fixture, loginShellPATH: "\(fixture.root)/login", processPATH: "\(fixture.root)/proc"), "claude"
        )
        #expect(found.candidates.map(\.source) == [.loginShell, .appProcess, .systemPaths, .knownLocation])
        #expect(found.candidates.map(\.path) == [
            "\(fixture.root)/login/claude", "\(fixture.root)/proc/claude", "\(fixture.root)/etc-bin/claude",
            "\(fixture.home)/.local/bin/claude"
        ])
        #expect(found.preferred?.path == "\(fixture.root)/login/claude")
    }

    @Test("a descriptor's own locations come before the common ones")
    func descriptorLocationsFirst() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("home/.claude/local/claude")
        try fixture.binary("home/.local/bin/claude")
        let found = try result(discover(fixture), "claude")
        #expect(found.candidates.map(\.path) == [
            "\(fixture.home)/.claude/local/claude", "\(fixture.home)/.local/bin/claude"
        ])
    }

    @Test("symlinks to one file are one candidate: the first path found, with the target as resolvedPath")
    func symlinkDedup() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let target = try fixture.binary("versions/1.2.3")
        try fixture.symlink("a/bin/claude", to: target)
        try fixture.symlink("b/bin/claude", to: target)
        let found = try result(
            discover(fixture, processPATH: "\(fixture.root)/a/bin:\(fixture.root)/b/bin"), "claude"
        )
        #expect(found.candidates.count == 1)
        #expect(found.candidates.first?.path == "\(fixture.root)/a/bin/claude")
        #expect(found.candidates.first?.resolvedPath == target)
    }

    @Test("a directory with a space in its name works")
    func spaceInPath() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("Application Support/x/bin/codex")
        let found = try result(discover(fixture, processPATH: "\(fixture.root)/Application Support/x/bin"), "codex")
        #expect(found.preferred?.path == "\(fixture.root)/Application Support/x/bin/codex")
    }

    @Test("a missing file, a non-executable file and a directory are not candidates")
    func notCandidates() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.directory("missing")
        try fixture.file("plain/claude", mode: 0o644)
        try fixture.directory("dir/claude")
        let path = ["missing", "plain", "dir"].map { "\(fixture.root)/\($0)" }.joined(separator: ":")
        #expect(try result(discover(fixture, processPATH: path), "claude").candidates.isEmpty)
        #expect(!ExecutableFile.isRunnable(atPath: "\(fixture.root)/dir/claude"))
    }

    @Test("an agy inside an app bundle is a refused candidate, never preferred or selectable")
    func agyInAppBundle() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let target = try fixture.binary("Applications/Foo.app/Contents/Resources/app/bin/agy")
        try fixture.symlink("bin/agy", to: target)
        let found = try result(discover(fixture, processPATH: "\(fixture.root)/bin"), "agy")
        #expect(found.candidates.count == 1)
        #expect(found.candidates.first?.refusal != nil)
        #expect(found.preferred == nil)
        #expect(found.selectable.isEmpty)
    }

    @Test("an env-interpreted script has a caveat and loses to a later binary, but is preferred alone")
    func envScript() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.file("node-bin/codex", contents: "#!/usr/bin/env node\n")
        let alone = try result(discover(fixture, processPATH: "\(fixture.root)/node-bin"), "codex")
        #expect(alone.preferred?.path == "\(fixture.root)/node-bin/codex")
        #expect(alone.preferred?.caveat?.contains("env node") == true)

        try fixture.binary("real/codex")
        let both = try result(
            discover(fixture, processPATH: "\(fixture.root)/node-bin:\(fixture.root)/real"), "codex"
        )
        #expect(both.candidates.count == 2)
        #expect(both.preferred?.path == "\(fixture.root)/real/codex")
    }

    @Test("candidates are listed in search order and the first is preferred")
    func searchOrder() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        try fixture.binary("one/codex")
        try fixture.binary("two/codex")
        let found = try result(discover(fixture, processPATH: "\(fixture.root)/one:\(fixture.root)/two"), "codex")
        #expect(found.candidates.map(\.path) == ["\(fixture.root)/one/codex", "\(fixture.root)/two/codex"])
        #expect(found.preferred == found.candidates.first)
    }

    @Test("supported means the app has an adapter for the CLI")
    func supported() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let stranger = AgentCLIDescriptor(cli: "zz-test-cli", vendorName: "Test", executableNames: ["zz"])
        let results = discover(fixture, descriptors: AgentCLIDescriptors.all + [stranger])
        #expect(results.map(\.descriptor.cli) == ["claude", "codex", "agy", "zz-test-cli"])
        #expect(results.map(\.isSupported) == [true, true, true, false])
    }

    @Test("every registered CLI Adapter has exactly one descriptor")
    func registryConsistency() {
        let clis = AgentCLIDescriptors.all.map(\.cli)
        #expect(Set(clis).count == clis.count)
        for name in RegisteredCLIAdapters.names {
            #expect(clis.contains(name))
        }
    }

    @Test("version directories sort newest first")
    func versionsOrder() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        for version in ["v18.2.0", "v20.11.1", "v9.0.0"] {
            try fixture.directory("home/.nvm/versions/node/\(version)/bin")
        }
        let directories = CLISearchLocation.versions(parent: ".nvm/versions/node", suffix: "bin")
            .directories(homeDirectory: fixture.home)
        let versions = directories.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").last }
        #expect(versions.map { $0.map(String.init) } == ["v20.11.1", "v18.2.0", "v9.0.0"])
        let missing = CLISearchLocation.versions(parent: "nope", suffix: "bin")
        #expect(missing.directories(homeDirectory: fixture.home).isEmpty)
    }

    @Test("a script's interpreter is read from its #! line")
    func interpreters() throws {
        let fixture = try CLIDiscoveryFixture()
        defer { fixture.remove() }
        let env = try fixture.file("env-script", contents: "#!/usr/bin/env node\nx")
        let direct = try fixture.file("sh-script", contents: "#!/bin/sh\nx")
        let binary = try fixture.binary("binary")
        #expect(ExecutableFile.interpreter(atPath: env) == .init(path: "/usr/bin/env", program: "node", viaEnv: true))
        #expect(ExecutableFile.interpreter(atPath: direct) == .init(path: "/bin/sh", program: "sh", viaEnv: false))
        #expect(ExecutableFile.interpreter(atPath: binary) == nil)
    }
}
