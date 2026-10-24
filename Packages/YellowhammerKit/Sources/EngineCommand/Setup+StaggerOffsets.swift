import Config
import Domain
import Foundation

extension Setup {
    /// What recording the Stagger Offsets left: the eligible Projects with their `[schedule]` as now
    /// recorded, and whether a Project could not be given one.
    struct StaggerRecording {
        var projects: [ProjectConfiguration]
        var failed: Bool
    }

    /// Records `stagger_minutes` in every eligible Project that lacks one, before any of its jobs are
    /// generated (Schedule Stagger Ruling): the lowest free multiple of ``Schedule/staggerStepMinutes``,
    /// in sorted Project id order. The Project file is edited textually, so every other line and comment
    /// survives, and the edited text is re-parsed before it is written. A Project whose lowest free offset
    /// does not fit its Night window, or whose file cannot be edited, is left out of the result — nothing is
    /// written to its file, none of its jobs are generated — and its siblings are still scheduled.
    func recordStaggerOffsets(
        configuration: Configuration, machine: MachineConfiguration, eligible: [ProjectConfiguration]
    ) -> StaggerRecording {
        let outcomes = StaggerAssignment.assignments(
            for: configuration.projects, eligible: Set(eligible.map(\.id))
        )
        var assigned: [ProjectID: Int] = [:]
        var skipped: Set<ProjectID> = []
        for (id, outcome) in outcomes {
            switch outcome {
            case .assigned(let offset):
                if let message = writeStaggerMinutes(offset, for: id, machine: machine) {
                    output("Project \(id): \(message)") // glossary:ignore GL001
                    skipped.insert(id)
                } else {
                    output("Project \(id): recorded stagger_minutes = \(offset)") // glossary:ignore GL001
                    assigned[id] = offset
                }
            case .beyondWindow(let offset, let windowMinutes):
                output(
                    "Project \(id): no Stagger Offset assigned: the lowest free offset, " // glossary:ignore GL001
                        + "\(offset) minutes, is not inside the \(windowMinutes)-minute Night window; "
                        + "no jobs generated"
                )
                skipped.insert(id)
            }
        }
        var projects: [ProjectConfiguration] = []
        for var project in eligible where !skipped.contains(project.id) {
            if let offset = assigned[project.id] { project.schedule.staggerMinutes = offset }
            projects.append(project)
        }
        return StaggerRecording(projects: projects, failed: !skipped.isEmpty)
    }

    /// Writes `stagger_minutes = offset` into the Project's file; returns why it could not, nil on success.
    private func writeStaggerMinutes(_ offset: Int, for id: ProjectID, machine: MachineConfiguration) -> String? {
        let url = configurationDirectory.appending(
            components: "projects", "\(id.rawValue).toml", directoryHint: .notDirectory
        )
        let path = url.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "could not read \(path): \(error)"
        }
        let updated = ProjectConfiguration.settingStaggerMinutes(offset, inFileText: text)
        guard updated != text else { return "could not record stagger_minutes in \(path)" }
        do {
            _ = try ProjectConfiguration.parse(
                updated, file: path, declaredCLIAdapters: Set(machine.cliAdapters.map(\.name)),
                declaredLinearInstallations: Set(machine.linearInstallations.map(\.name)),
                declaredCodeHostingConnections: Set(machine.codeHostingConnections.map(\.name))
            )
        } catch {
            return "could not record stagger_minutes: \(error)"
        }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "could not write \(path): \(error)"
        }
        return nil
    }
}
