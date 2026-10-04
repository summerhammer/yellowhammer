import AppKit
import Config
import SwiftUI

/// The base Routing Table pane of the Settings window's General section, reached from its sidebar or from a
/// Project's "Base Routing Table…" button (P14.3, P18.15). Not Project-scoped: this is `config.toml`'s
/// `[[routing]]`, shared by every Project.
struct BaseRoutingTablePane: View {
    @State private var model = BaseRoutingTableModel()

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfClean()
            }
    }

    @ViewBuilder private var content: some View {
        if model.routingTable != nil {
            BaseRoutingTableFormView(model: model)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        SettingsUnavailable(message: model.loadFailure ?? "The base Routing Table could not be loaded.")
    }
}

/// The form itself, split out so it only ever runs with a non-nil table: `model.routingTable` is
/// unwrapped once here via `Binding($model.routingTable)`.
private struct BaseRoutingTableFormView: View {
    @Bindable var model: BaseRoutingTableModel

    var body: some View {
        if let table = Binding($model.routingTable) {
            SettingsPane(
                title: "Base Routing Table",
                explanation: "The Route \u{2014} agent CLI, model and effort \u{2014} for each Kind and Repo Role, "
                    + "with its fallbacks in order. Every Project on this Mac reads this table; a Project\u{2019}s "
                    + "own entry for the same Kind and Repo Role replaces the one here."
            ) {
                WizardBlock(
                    title: "Routing Table",
                    footer: "A blank Kind or Repo Role matches any. Fallbacks are tried in order.",
                    boxed: false
                ) {
                    RoutingEntriesEditor(entries: table, emptyText: "No route yet. Add one to dispatch Cards.")
                }
                if let adapters = model.machine?.cliAdapters, !adapters.isEmpty {
                    WizardBlock(title: "Declared CLI Adapters", footer: "Declared in the Agent CLIs pane.") {
                        ForEach(adapters, id: \.name) { adapter in
                            Text(adapter.name)
                                .font(.body.monospaced())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            if adapter.name != adapters.last?.name {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            } footer: {
                SettingsSaveFooter(
                    note: "Saving rewrites \(model.file.path(percentEncoded: false)); comments and layout in it "
                        + "are not kept. Editing the file directly stays supported.",
                    failure: model.failure,
                    isDirty: model.isDirty,
                    identifierPrefix: "routing-table",
                    onRevert: { model.revert() },
                    onSave: { model.save() }
                )
            }
        } else {
            SettingsUnavailable(message: "The base Routing Table could not be loaded.")
        }
    }
}
