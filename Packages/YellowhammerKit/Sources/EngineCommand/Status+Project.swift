import Config
import Domain
import Foundation
import Journal

extension Status {
    /// Gathers one Project's whole section: its job states, its Journal-derived last run/last
    /// Night/missed Nights, and the sleep intervals overlapping its examined Night windows.
    func projectStatus(
        project: ProjectConfiguration, staggerIndex: Int, disabledLabels: Set<String>, sleepHistory: SleepHistory?
    ) async -> ProjectStatus {
        let jobs = await jobStates(projectID: project.id, disabledLabels: disabledLabels)
        let journal = journalStatus(projectID: project.id)
        let missed = missedNights(
            project: project, staggerIndex: staggerIndex, journal: journal, jobs: jobs, sleepHistory: sleepHistory
        )
        let examinedWindows = MissedNightDiagnosis.endedWindows(
            schedule: project.schedule, now: now, calendar: calendar, count: examinedNights
        )
        let sleepIntervals = Self.overlappingSleepIntervals(
            sleepHistory: sleepHistory, examinedWindows: examinedWindows
        )

        return ProjectStatus(
            projectID: project.id, lastRun: journal.lastRun, lastNight: journal.lastNight, jobs: jobs,
            sleepIntervals: sleepIntervals, sleepHistoryUnavailable: sleepHistory == nil, missedNights: missed
        )
    }

    private static func overlappingSleepIntervals(
        sleepHistory: SleepHistory?, examinedWindows: [NightWindow]
    ) -> [SleepInterval] {
        guard let sleepHistory else { return [] }
        return sleepHistory.intervals.filter { interval in
            examinedWindows.contains { window in interval.start < window.end && interval.end > window.start }
        }
    }
}

extension Status {
    /// The state of every one of this Project's three LaunchAgents, in `Act.allCases` order.
    func jobStates(
        projectID: ProjectID, disabledLabels: Set<String>
    ) async -> [(act: Act, state: LaunchAgentJobState)] {
        var states: [(act: Act, state: LaunchAgentJobState)] = []
        for act in Act.allCases {
            states.append((act, await jobState(projectID: projectID, act: act, disabledLabels: disabledLabels)))
        }
        return states
    }

    private func jobState(projectID: ProjectID, act: Act, disabledLabels: Set<String>) async -> LaunchAgentJobState {
        let label = Self.launchAgentLabel(projectID: projectID, act: act)
        let plistURL = launchAgentsDirectory.appending(component: "\(label).plist", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) else {
            return .notInstalled
        }
        guard !disabledLabels.contains(label) else { return .disabled }
        guard let info = await launchAgents.jobInfo(label: label) else { return .notLoaded }
        return .loaded(runs: info.runs, lastExitCode: info.lastExitCode)
    }

    static func launchAgentLabel(projectID: ProjectID, act: Act) -> String {
        "com.summerhammer.yellowhammer.\(projectID.rawValue).\(act.rawValue)"
    }
}
