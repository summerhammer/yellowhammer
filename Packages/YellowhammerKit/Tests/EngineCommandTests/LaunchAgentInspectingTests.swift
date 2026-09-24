@testable import EngineCommand
import Testing

@Suite("launchctl output parsers")
struct LaunchAgentInspectingTests {
    @Test("parseJobInfo reads the top-level runs and last exit code")
    func parseJobInfoReadsTopLevelFields() {
        let text = """
            com.summerhammer.yellowhammer.alpha.build = {
            \tactive count = 1
            \tpath = /Users/max/Library/LaunchAgents/com.summerhammer.yellowhammer.alpha.build.plist
            \truns = 3
            \tlast exit code = 1
            \tspawn type = daemon
            }
            """
        let info = LaunchctlLaunchAgentControl.parseJobInfo(text)
        #expect(info == LaunchctlJobInfo(runs: 3, lastExitCode: 1))
    }

    @Test("parseJobInfo reads '(never exited)' as a nil last exit code")
    func parseJobInfoNeverExited() {
        let text = "\truns = 1\n\tlast exit code = (never exited)\n"
        let info = LaunchctlLaunchAgentControl.parseJobInfo(text)
        #expect(info == LaunchctlJobInfo(runs: 1, lastExitCode: nil))
    }

    @Test("parseJobInfo ignores nested, more deeply indented fields")
    func parseJobInfoIgnoresNestedFields() {
        let text = """
            \truns = 2
            \tsome nested dictionary = {
            \t\truns = 999
            \t\tlast exit code = 42
            \t}
            \tlast exit code = 0
            """
        let info = LaunchctlLaunchAgentControl.parseJobInfo(text)
        #expect(info == LaunchctlJobInfo(runs: 2, lastExitCode: 0))
    }

    @Test("parseJobInfo keeps only the first occurrence of each top-level field")
    func parseJobInfoKeepsFirstOccurrence() {
        let text = "\truns = 1\n\truns = 2\n\tlast exit code = 0\n\tlast exit code = 1\n"
        let info = LaunchctlLaunchAgentControl.parseJobInfo(text)
        #expect(info == LaunchctlJobInfo(runs: 1, lastExitCode: 0))
    }

    @Test("parseDisabledLabels reads '=> disabled' lines")
    func parseDisabledLabelsReadsDisabled() {
        let text = """
            disabled services = {
            \t\t"com.summerhammer.yellowhammer.alpha.author" => disabled
            \t\t"com.summerhammer.yellowhammer.alpha.build" => enabled
            }
            """
        let labels = LaunchctlLaunchAgentControl.parseDisabledLabels(text)
        #expect(labels == ["com.summerhammer.yellowhammer.alpha.author"])
    }

    @Test("parseDisabledLabels also accepts '=> true' (older macOS)")
    func parseDisabledLabelsAcceptsTrue() {
        let text = """
            \t\t"com.summerhammer.yellowhammer.alpha.land" => true
            \t\t"com.summerhammer.yellowhammer.alpha.build" => false
            """
        let labels = LaunchctlLaunchAgentControl.parseDisabledLabels(text)
        #expect(labels == ["com.summerhammer.yellowhammer.alpha.land"])
    }

    @Test("parseDisabledLabels finds no labels in an empty dump")
    func parseDisabledLabelsEmpty() {
        #expect(LaunchctlLaunchAgentControl.parseDisabledLabels("disabled services = {\n}\n").isEmpty)
    }
}
