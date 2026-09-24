@testable import EngineCommand
import Config
import Domain
import Foundation
import Testing

@Suite("ScheduledJob: plist rendering")
struct ScheduledJobPlistTests {
    @Test("plistData: round-trips every required key and omits forbidden ones")
    func plistRoundTrip() throws {
        let projectID = ProjectID(rawValue: "acme")!
        let job = ScheduledJob(
            projectID: projectID,
            act: .author,
            yhExecutablePath: "/usr/local/bin/yh",
            firings: [TimeOfDay(hour: 22, minute: 0)!, TimeOfDay(hour: 22, minute: 15)!],
            pathValue: "/usr/local/bin:/usr/bin:/bin"
        )

        #expect(job.label == "dev.yellowhammer.acme.author")
        #expect(job.fileName == "dev.yellowhammer.acme.author.plist")

        let data = try job.plistData(homeDirectory: "/Users/fixture")
        var format = PropertyListSerialization.PropertyListFormat.xml
        let decoded = try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        )

        #expect(format == .xml)
        #expect(decoded["Label"] as? String == "dev.yellowhammer.acme.author")
        #expect(decoded["ProgramArguments"] as? [String] == ["/usr/local/bin/yh", "author", "--project", "acme"])

        let intervals = try #require(decoded["StartCalendarInterval"] as? [[String: Int]])
        #expect(intervals == [["Hour": 22, "Minute": 0], ["Hour": 22, "Minute": 15]])

        let environment = try #require(decoded["EnvironmentVariables"] as? [String: String])
        #expect(environment == ["PATH": "/usr/local/bin:/usr/bin:/bin"])

        let expectedLog = "/Users/fixture/Library/Logs/Yellowhammer/acme.author.log"
        #expect(decoded["StandardOutPath"] as? String == expectedLog)
        #expect(decoded["StandardErrorPath"] as? String == expectedLog)

        #expect(decoded["RunAtLoad"] == nil)
        #expect(decoded["KeepAlive"] == nil)
        #expect(decoded["ProcessType"] == nil)
    }
}

@Suite("ScheduledJob: cron rendering")
struct ScheduledJobCronTests {
    @Test("cronLines: groups hours sharing an identical minute list")
    func cronGrouping() throws {
        let projectID = ProjectID(rawValue: "acme")!
        let job = ScheduledJob(
            projectID: projectID,
            act: .build,
            yhExecutablePath: "/usr/local/bin/yh",
            firings: [
                TimeOfDay(hour: 22, minute: 15)!, TimeOfDay(hour: 22, minute: 45)!,
                TimeOfDay(hour: 23, minute: 15)!, TimeOfDay(hour: 23, minute: 45)!,
                TimeOfDay(hour: 0, minute: 0)!
            ],
            pathValue: "/usr/local/bin:/usr/bin:/bin"
        )

        let lines = ScheduledJob.cronLines(
            for: [job], pathValue: "/usr/local/bin:/usr/bin:/bin", homeDirectory: "/Users/fixture"
        )

        let expectedLog = "/Users/fixture/Library/Logs/Yellowhammer/acme.build.log"
        // Groups are emitted in ascending numeric hour order (00 before 22-23): a Night that wraps past
        // midnight sorts its post-midnight hours first, which is fine — cron itself is hour-order-blind.
        #expect(lines == [
            "PATH=/usr/local/bin:/usr/bin:/bin",
            "# dev.yellowhammer.acme.build",
            "0 0 * * * /usr/local/bin/yh build --project acme >> \(expectedLog) 2>&1",
            "15,45 22,23 * * * /usr/local/bin/yh build --project acme >> \(expectedLog) 2>&1"
        ])
    }

    @Test("shellQuoted: quotes a path containing a space, leaves a plain path bare")
    func shellQuotingASpace() throws {
        #expect(ScheduledJob.shellQuoted("/usr/local/bin/yh") == "/usr/local/bin/yh")
        #expect(ScheduledJob.shellQuoted("/Users/max/My Tools/yh") == "'/Users/max/My Tools/yh'")
    }

    @Test("cronLines: skips a job with no firings")
    func cronSkipsEmptyJob() throws {
        let projectID = ProjectID(rawValue: "acme")!
        let job = ScheduledJob(
            projectID: projectID, act: .land, yhExecutablePath: "/usr/local/bin/yh", firings: [],
            pathValue: "/usr/local/bin:/usr/bin:/bin"
        )
        let lines = ScheduledJob.cronLines(
            for: [job], pathValue: "/usr/local/bin:/usr/bin:/bin", homeDirectory: "/Users/fixture"
        )
        #expect(lines == ["PATH=/usr/local/bin:/usr/bin:/bin"])
    }
}

@Suite("ScheduledJob: PATH composition")
struct ScheduledJobPATHTests {
    @Test("composePATH: resolved tool directories first, then setup PATH, then the POSIX default")
    func composePATHOrderAndDedupe() throws {
        let composed = ScheduledJob.composePATH(
            setupTimePATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin",
            resolvedToolPaths: ["/opt/homebrew/bin/git", "/usr/local/bin/orca"]
        )
        #expect(composed == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("composePATH: skips empty entries")
    func composePATHSkipsEmptyEntries() throws {
        let composed = ScheduledJob.composePATH(setupTimePATH: "/usr/local/bin::/usr/bin:", resolvedToolPaths: [])
        #expect(composed == "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
}

@Suite("ScheduledJob: bare-environment resolution")
struct ScheduledJobBareEnvironmentTests {
    @Test("unresolvableTools: reports a missing declared adapter and clears once its directory is on PATH")
    func unresolvableToolsReportsMissingThenClears() throws {
        let path = "/usr/local/bin:/usr/bin"
        let declaredAdapters = [CLIAdapterDeclaration(name: "orca", executable: nil)]

        let missing = ScheduledJob.unresolvableTools(
            composedPATH: path, declaredCLIAdapters: declaredAdapters,
            fileExists: { candidate in candidate == "/usr/bin/git" }
        )
        #expect(missing == ["orca"])

        let resolved = ScheduledJob.unresolvableTools(
            composedPATH: path, declaredCLIAdapters: declaredAdapters,
            fileExists: { candidate in candidate == "/usr/bin/git" || candidate == "/usr/local/bin/orca" }
        )
        #expect(resolved.isEmpty)
    }

    @Test("unresolvableTools: a declared absolute executable always resolves, regardless of PATH")
    func unresolvableToolsHonorsDeclaredExecutable() throws {
        let declaredAdapters = [CLIAdapterDeclaration(name: "orca", executable: "/opt/orca/bin/orca")]
        let missing = ScheduledJob.unresolvableTools(
            composedPATH: "/usr/bin", declaredCLIAdapters: declaredAdapters,
            fileExists: { _ in false }
        )
        #expect(missing == ["git"])
    }
}
