import Config
import Domain
import Foundation
import Journal

extension Status {
    func printInvalidProjectSection(_ status: InvalidProjectStatus) {
        let heading = status.id.map { "Project \($0)" } ?? "Project (\(status.file))" // glossary:ignore GL001
        output("\(heading):")
        output("  \(status.file): Acts exit before initializing (pre-initialization crash)")
        for error in status.errors {
            output("    \(error)")
        }
    }

    func printProjectSection(_ status: ProjectStatus) {
        output("Project \(status.projectID):") // glossary:ignore GL001
        output("  last run: \(lastRunLine(status.lastRun))")
        output("  last Night: \(lastNightLine(status.lastNight))")
        for job in status.jobs {
            output("  \(job.act.rawValue): \(jobStateText(job.state))")
        }
        output("  sleep and wake: \(sleepLine(status))")
        printMissedNights(status.missedNights)
    }

    private func printMissedNights(_ missedNights: [MissedNight]) {
        output("  missed Nights:")
        guard !missedNights.isEmpty else {
            output("    none")
            return
        }
        for missed in missedNights {
            output("    \(missed.window.nightStart): \(causeLine(missed.cause))")
        }
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

extension Status {
    private func lastRunLine(_ status: LastRunStatus) -> String {
        switch status {
        case .noJournal:
            return "no Journal: this Project has never run an Act" // glossary:ignore GL001
        case .journalError(let message):
            return message
        case .noRunRecorded:
            return "no Act has run yet"
        case .run(let act, let runID, let firstEventAt, let ending):
            let started = formattedDate(firstEventAt)
            return "\(act.rawValue) run \(runID.rawValue) started \(started): \(endingText(ending))"
        }
    }

    private func endingText(_ ending: LastRunEnding) -> String {
        switch ending {
        case .ended: "ended"
        case .idle(let reason): "idle (\(reason.rawValue))"
        case .incomplete(let reason): "incomplete: \(reason)"
        case .stoodDown: "stood down"
        case .runningNow: "running now"
        case .noEndingRecorded: "no ending recorded"
        }
    }

    private func lastNightLine(_ night: NightRecord?) -> String {
        guard let night else { return "none" }
        var line = "\(night.nightStart) \(night.state.rawValue)" // glossary:ignore GL001
        if let reason = night.closeReason {
            line += " (\(reason.rawValue))"
        }
        if let verdict = night.verdict {
            line += ", verdict \(verdict.rawValue)"
        }
        return line
    }

    private func jobStateText(_ state: LaunchAgentJobState) -> String {
        switch state {
        case .notInstalled: return "not installed"
        case .disabled: return "disabled"
        case .notLoaded: return "not loaded" // glossary:ignore GL001
        case .loaded(let runs, let lastExitCode):
            let runsText = runs.map(String.init) ?? "unknown"
            let exitText = lastExitCode.map(String.init) ?? "(never exited)"
            return "loaded, runs \(runsText), last exit code \(exitText)"
        }
    }

    private func sleepLine(_ status: ProjectStatus) -> String {
        if status.sleepHistoryUnavailable { return "sleep history unavailable" }
        guard !status.sleepIntervals.isEmpty else { return "no sleep recorded" }
        return status.sleepIntervals
            .map { "asleep \(formattedDate($0.start)) \u{2192} \(formattedDate($0.end))" }
            .joined(separator: "; ")
    }

    private func causeLine(_ cause: MissedNightCause) -> String {
        switch cause {
        case .preInitializationCrash(let evidence):
            return "`yh` started but exited before opening the Night " // glossary:ignore GL001
                + "(pre-initialization crash): \(evidence.joined(separator: "; "))"
        case .noRunnableJob(let jobs):
            return noRunnableJobText(jobs)
        case .asleep(let intervals):
            let text = intervals
                .map { "\(formattedDate($0.start)) \u{2192} \(formattedDate($0.end))" }
                .joined(separator: "; ")
            return "the Mac was asleep at every firing (asleep \(text))"
        case .undiagnosed(let reachesBack):
            let suffix = reachesBack ? "" : "; sleep history does not reach back this far"
            return "undiagnosed: jobs are loaded, and no sleep interval explains it\(suffix)"
        }
    }

    private func noRunnableJobText(_ jobs: [Act: LaunchAgentJobState]) -> String {
        let text = Act.allCases
            .compactMap { act in jobs[act].map { "\(act.rawValue) \(jobStateText($0))" } }
            .joined(separator: ", ")
        return "no LaunchAgent can fire: \(text); run `yh setup --install-jobs`" // glossary:ignore GL001
    }
}
