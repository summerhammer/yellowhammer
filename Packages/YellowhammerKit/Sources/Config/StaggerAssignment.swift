import Domain

/// Setup's assignment of Stagger Offsets (Schedule Stagger Ruling): a Project that records no
/// `stagger_minutes` gets the lowest multiple of ``Schedule/staggerStepMinutes`` that no other configured
/// Project's recorded value holds, in sorted Project id order. Pure arithmetic — no IO — so it is testable
/// without a file system.
public enum StaggerAssignment {
    /// One Project's outcome: the offset setup records, or the lowest free offset when it does not fit the
    /// Project's Night window.
    public enum Outcome: Equatable, Sendable {
        case assigned(Int)
        /// The lowest free offset is at or past the window's length: nothing is recorded or scheduled.
        case beyondWindow(offset: Int, windowMinutes: Int)
    }

    /// The outcome for every Project among `projects` that records no `stagger_minutes`, in sorted id
    /// order. Every Project's recorded value counts as held — including the ones assigned earlier in this
    /// run, but not a `beyondWindow` one, which records nothing. Coinciding Operator-set values are fine.
    /// A Project that already records one gets no entry.
    ///
    /// `eligible` narrows who is assigned (a Project whose provisioning failed is not scheduled) without
    /// narrowing whose recorded value is held; nil assigns every Project that lacks one.
    public static func assignments(
        for projects: [ProjectConfiguration], eligible: Set<ProjectID>? = nil
    ) -> [(ProjectID, Outcome)] {
        var held = Set(projects.compactMap(\.schedule.staggerMinutes))
        var result: [(ProjectID, Outcome)] = []
        for project in projects.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        where project.schedule.staggerMinutes == nil && eligible?.contains(project.id) != false {
            var offset = 0
            while held.contains(offset) { offset += Schedule.staggerStepMinutes }
            let window = project.schedule.windowLengthMinutes
            if offset < window {
                held.insert(offset)
                result.append((project.id, .assigned(offset)))
            } else {
                result.append((project.id, .beyondWindow(offset: offset, windowMinutes: window)))
            }
        }
        return result
    }
}
