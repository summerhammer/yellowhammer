import ArgumentParser
import Config
@testable import EngineCommand
import Foundation
import Testing

@Suite("yh setup option parsing")
struct SetupOptionsParsingTests {
    @Test("--repo keeps commas inside the check command")
    func repoKeepsCommasInCheck() throws {
        let arguments = makeArguments(
            operatorID: "user-op", project: "demo", linearProject: "proj-1",
            repo: ["backend,backend,~/dev/backend,swift test --filter \"a,b\""]
        )
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.repos.count == 1)
        #expect(options.repos[0].check == .command(#"swift test --filter "a,b""#))
    }

    @Test("--linear-project with --linear-team is refused") // glossary:ignore GL001
    func linearProjectWithLinearTeamRefused() {
        let arguments = makeArguments(project: "demo", linearProject: "proj-1", linearTeam: "ENG")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("Project options without --project are refused") // glossary:ignore GL001
    func projectOptionsWithoutProjectRefused() {
        let arguments = makeArguments(projectName: "Demo")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--night-start, --night-end and --build-every-minutes parse into the schedule")
    func scheduleOptionsParse() throws {
        let arguments = makeArguments(
            project: "demo", linearProject: "proj-1",
            nightStart: "23:30", nightEnd: "05:15", buildEveryMinutes: "20"
        )
        let options = try SetupOptions(command: try SetupCommand.parse(arguments))
        #expect(options.schedule.nightStart == TimeOfDay(hour: 23, minute: 30))
        #expect(options.schedule.nightEnd == TimeOfDay(hour: 5, minute: 15))
        #expect(options.schedule.buildEveryMinutes == 20)
    }

    @Test("Omitted schedule options keep the defaults")
    func omittedScheduleOptionsKeepDefaults() throws {
        let arguments = makeArguments(project: "demo", linearProject: "proj-1", nightEnd: "07:00")
        let options = try SetupOptions(command: try SetupCommand.parse(arguments))
        #expect(options.schedule.nightStart == Schedule().nightStart)
        #expect(options.schedule.nightEnd == TimeOfDay(hour: 7, minute: 0))
        #expect(options.schedule.buildEveryMinutes == Schedule().buildEveryMinutes)
    }

    @Test("Schedule options without --project are refused", arguments: [
        makeArguments(nightStart: "22:00"),
        makeArguments(nightEnd: "06:00"),
        makeArguments(buildEveryMinutes: "15")
    ])
    func scheduleOptionsWithoutProjectRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("A malformed time or a non-integer build interval is refused, naming the flag", arguments: [
        (makeArguments(project: "demo", linearProject: "proj-1", nightStart: "25:00"), "--night-start"),
        (makeArguments(project: "demo", linearProject: "proj-1", nightEnd: "6am"), "--night-end"),
        (makeArguments(project: "demo", linearProject: "proj-1", buildEveryMinutes: "often"), "--build-every-minutes")
    ])
    func malformedScheduleOptionRefused(arguments: [String], flag: String) throws {
        do {
            _ = try SetupCommand.parse(arguments)
            Issue.record("expected a validation error")
        } catch {
            #expect(SetupCommand.message(for: error).contains(flag))
        }
    }

    @Test("A --fallback without --route is refused")
    func fallbackWithoutRouteRefused() {
        let arguments = makeArguments(cli: ["claude"], fallback: ["claude/opus/high"])
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("An unknown --cli is refused")
    func unknownCLIRefused() {
        let arguments = makeArguments(cli: ["not-a-real-cli"])
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("Running without --init or --config is interactive and does not throw")
    func withoutInitOrConfigIsInteractive() throws {
        let arguments = makeArguments(initialize: false)
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.mode == .interactive)
    }

    @Test("--config with --init is refused")
    func configWithInitRefused() {
        let arguments = makeArguments(initialize: true, config: "/tmp/prepared")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--config with a generating option is refused", arguments: [
        makeArguments(initialize: false, config: "/tmp/prepared", cli: ["claude"]),
        makeArguments(initialize: false, config: "/tmp/prepared", route: "claude/sonnet/medium"),
        makeArguments(
            initialize: false, config: "/tmp/prepared", cli: ["claude"], route: "claude/sonnet/medium",
            fallback: ["claude/opus/high"]
        ),
        makeArguments(initialize: false, config: "/tmp/prepared", project: "demo")
    ])
    func configWithGeneratingOptionRefused(arguments: [String]) {
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--install-jobs with --export-jobs is refused")
    func installJobsWithExportJobsRefused() {
        let arguments = makeArguments(operatorID: "user-op", installJobs: true, exportJobs: "/tmp/jobs")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--cron without --export-jobs is refused")
    func cronWithoutExportJobsRefused() {
        let arguments = makeArguments(operatorID: "user-op", cron: true)
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--cron parses with --export-jobs, as .export(_, format: .cron)")
    func cronParsesWithExportJobs() throws {
        let arguments = makeArguments(operatorID: "user-op", exportJobs: "/tmp/jobs", cron: true)
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(
            options.jobs == .export(URL(filePath: "/tmp/jobs", directoryHint: .isDirectory), format: .cron)
        )
    }

    @Test("--install-jobs alone parses as .install")
    func installJobsAloneParses() throws {
        let arguments = makeArguments(operatorID: "user-op", installJobs: true)
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.jobs == .install)
    }

    @Test("--config allows --operator")
    func configAllowsOperator() throws {
        let arguments = makeArguments(
            initialize: false, config: "/tmp/prepared", operatorID: "user-op"
        )
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.mode == .config(URL(filePath: "/tmp/prepared", directoryHint: .isDirectory)))
    }

    @Test("--install-linear alone parses as .installLinear, interactive")
    func installLinearAloneParses() throws {
        let arguments = makeArguments(initialize: false, installLinear: true)
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.mode == .installLinear)
        #expect(!options.eventsJSON)
    }

    @Test("--install-linear --events json parses non-interactive")
    func installLinearWithEventsJSONParses() throws {
        let arguments = makeArguments(initialize: false, installLinear: true, events: "json")
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.mode == .installLinear)
        #expect(options.eventsJSON)
    }

    @Test("--install-linear with --init is refused")
    func installLinearWithInitRefused() {
        let arguments = makeArguments(initialize: true, installLinear: true)
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--events with a value other than json is refused")
    func eventsWithOtherValueRefused() {
        let arguments = makeArguments(initialize: false, installLinear: true, events: "text")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--events without --install-linear is refused")
    func eventsWithoutInstallLinearRefused() {
        let arguments = makeArguments(initialize: false, events: "json")
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--remote alone is refused")
    func remoteAloneRefused() {
        let arguments = makeArguments(initialize: false, remote: true)
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }

    @Test("--install-linear --remote gives remoteApproval == true") // glossary:ignore GL001
    func installLinearRemoteParses() throws {
        let arguments = makeArguments(initialize: false, installLinear: true, remote: true)
        let command = try SetupCommand.parse(arguments)
        let options = try SetupOptions(command: command)
        #expect(options.mode == .installLinear)
        #expect(options.remoteApproval)
    }

    @Test("--print-choices cannot be combined with --install-linear")
    func printChoicesCannotCombineWithInstallLinear() {
        let arguments = ["--print-choices", "--install-linear"] // glossary:ignore GL001
        #expect(throws: (any Error).self) { try SetupCommand.parse(arguments) }
    }
}
