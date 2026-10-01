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
        VStack(spacing: 8) {
            Text(model.loadFailure ?? "The base Routing Table could not be loaded.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

/// The form itself, split out so it only ever runs with a non-nil table: `model.routingTable` is
/// unwrapped once here via `Binding($model.routingTable)`.
private struct BaseRoutingTableFormView: View {
    @Bindable var model: BaseRoutingTableModel

    var body: some View {
        if let table = Binding($model.routingTable) {
            VStack(spacing: 0) {
                Form {
                    Section("Routing Table") {
                        RoutingEntriesEditor(entries: table)
                    }
                    if let adapters = model.machine?.cliAdapters, !adapters.isEmpty {
                        Section("Declared CLI Adapters") {
                            ForEach(adapters, id: \.name) { adapter in
                                Text(adapter.name)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                Divider()
                footer
            }
        } else {
            Text("The base Routing Table could not be loaded.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("routing-table-save-failure")
            }
            Text(
                "Saving rewrites \(model.file.path(percentEncoded: false)); comments and layout in it "
                    + "are not kept. Editing the file directly stays supported."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("routing-table-revert")
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("routing-table-save")
            }
        }
        .padding()
    }
}
