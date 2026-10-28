import Observation

/// Stops the Settings window leaving a Project whose instructions draft is unsaved.
///
/// The window gives each Project its own pane, so leaving one destroys its state. The visible Project pane
/// registers its ``ProjectInstructionsModel``; every navigation the window makes goes through
/// ``navigate(_:)``, which runs at once when the draft is clean and otherwise holds the move until the
/// Operator chose to save, discard or cancel.
@MainActor
@Observable
final class ProjectInstructionsGuard {
    @ObservationIgnored private var model: ProjectInstructionsModel?
    /// The move waiting for the Operator's choice; non-nil while the confirmation is shown.
    private(set) var pending: (@MainActor () -> Void)?

    var isConfirming: Bool {
        get { pending != nil }
        set { if !newValue { pending = nil } }
    }

    func register(_ model: ProjectInstructionsModel) {
        self.model = model
    }

    /// A pane that disappears after a newer one registered must not unregister the newer one.
    func unregister(_ model: ProjectInstructionsModel) {
        if self.model === model { self.model = nil }
    }

    func navigate(_ move: @escaping @MainActor () -> Void) {
        if let model, model.isDirty {
            pending = move
        } else {
            move()
        }
    }

    /// Saves, then moves only if the save wrote. A conflict or rejection stays on the Project, where the
    /// editor shows it.
    func saveAndContinue() {
        guard let move = pending else { return }
        pending = nil
        if model?.save() == true { move() }
    }

    func discardAndContinue() {
        guard let move = pending else { return }
        pending = nil
        model?.discard()
        move()
    }

    func cancel() {
        pending = nil
    }
}
