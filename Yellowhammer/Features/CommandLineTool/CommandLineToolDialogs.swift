import SwiftUI

extension View {
    func commandLineToolDialogs(model: CommandLineToolModel) -> some View {
        modifier(CommandLineToolDialogModifier(model: model))
    }
}

private struct CommandLineToolDialogModifier: ViewModifier {
    @Bindable var model: CommandLineToolModel

    func body(content: Content) -> some View {
        content
            .alert(
                item: $model.pendingConfirmation
            ) { action in
                confirmationAlert(for: action)
            }
            .alert(
                "Command Line Tool",
                isPresented: Binding(
                    get: { model.lastError != nil },
                    set: { if !$0 { model.lastError = nil } }
                )
            ) {
                Button("OK") { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
    }

    private func confirmationAlert(for action: CommandLineToolModel.ConfirmationAction) -> Alert {
        switch action {
        case .install:
            Alert(
                title: Text("Install Command Line Tool at \(model.linkPath)?"),
                message: Text(
                    "This will create a symlink at \(model.linkPath) pointing to \(model.runningExecutablePath). " +
                    "macOS may ask for an administrator password. Scheduled jobs are unaffected."
                ),
                primaryButton: .default(Text("Install")) {
                    model.performInstall()
                },
                secondaryButton: .cancel {
                    model.pendingConfirmation = nil
                }
            )
        case .update:
            Alert(
                title: Text("Update Command Line Tool at \(model.linkPath)?"),
                message: Text(
                    "This will update the symlink at \(model.linkPath) to point to \(model.runningExecutablePath). " +
                    "macOS may ask for an administrator password. Scheduled jobs are unaffected."
                ),
                primaryButton: .default(Text("Update")) {
                    model.performInstall()
                },
                secondaryButton: .cancel {
                    model.pendingConfirmation = nil
                }
            )
        case .uninstall:
            Alert(
                title: Text("Uninstall Command Line Tool at \(model.linkPath)?"),
                message: Text(
                    "This will remove the symlink at \(model.linkPath). " +
                    "macOS may ask for an administrator password. Scheduled jobs are unaffected."
                ),
                primaryButton: .destructive(Text("Uninstall")) {
                    model.performUninstall()
                },
                secondaryButton: .cancel {
                    model.pendingConfirmation = nil
                }
            )
        case .moveDetected(let target):
            Alert(
                title: Text("Yellowhammer moved. Update the command line tool to point to its new location?"),
                message: Text(
                    "The Command Line Tool symlink at \(model.linkPath) points to a different copy " +
                    "(\(target)). Updating it will point to \(model.runningExecutablePath). " +
                    "macOS may ask for an administrator password. Scheduled jobs are unaffected."
                ),
                primaryButton: .default(Text("Update Command Line Tool")) {
                    model.performInstall()
                },
                secondaryButton: .cancel(Text("Not Now")) {
                    model.dismissMoveDetection(for: target)
                }
            )
        }
    }
}
