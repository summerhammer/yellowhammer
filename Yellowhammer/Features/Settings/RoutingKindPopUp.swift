import Domain
import SwiftUI

/// A Card's Kind, chosen from a pop-up button: every Kind this Mac's files name, indented by depth, and
/// "New Kind…" for one the list lacks. The reserved authoring Kind is never offered — the author Act and
/// Verification have sections of their own.
struct KindPopUp: View {
    /// What the pop-up chooses for.
    enum Purpose {
        /// A Routing Entry's Kind, where Any Kind is a choice.
        case entry
        /// The Kind of the Card "Test a Card" imagines, which always has one.
        case question
    }

    @Binding var value: String
    let purpose: Purpose
    /// The Kinds to offer, sorted, so a Kind sits under its parent.
    let kinds: [String]
    @State private var isAddingKind = false

    var body: some View {
        Menu {
            if purpose == .entry {
                choice("", title: "Any Kind")
                Divider()
            }
            ForEach(kinds, id: \.self) { kind in
                choice(kind, title: Self.indented(kind))
            }
            if !kinds.isEmpty { Divider() }
            Button("New Kind\u{2026}") { isAddingKind = true }
        } label: {
            Text(Self.title(of: value))
                .font(Self.isAny(value) ? .body : .body.monospaced())
        }
        .menuStyle(.button)
        .fixedSize()
        .popover(isPresented: $isAddingKind, arrowEdge: .bottom) {
            NewKindPopover { value = $0 }
        }
        .accessibilityLabel("Kind")
        .accessibilityValue(Self.title(of: value))
    }

    static func isAny(_ value: String) -> Bool { value.isEmpty || value == "*" }

    static func title(of value: String) -> String { isAny(value) ? "Any Kind" : value }

    /// A Kind with one indent per level below the first, so `impl.boilerplate` sits under `impl`.
    private static func indented(_ kind: String) -> String {
        let segments = kind.split(separator: ".")
        return String(repeating: "    ", count: max(segments.count - 1, 0)) + (segments.last.map(String.init) ?? kind)
    }

    private func choice(_ kind: String, title: String) -> some View {
        Button {
            value = kind
        } label: {
            if value == kind || (Self.isAny(value) && kind.isEmpty) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// A new Kind, typed as its dotted path: `impl`, or `impl.boilerplate` for one under `impl`.
struct NewKindPopover: View {
    let add: (String) -> Void
    @State private var kind = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Kind").font(.headline)
            TextField("Kind", text: $kind, prompt: Text("impl.boilerplate"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .labelsHidden()
                .onSubmit(addIfValid)
            Text(problem ?? "Segments joined by dots. Cards whose Kind starts with it will match.")
                .font(.caption)
                .foregroundStyle(problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.error))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: addIfValid)
                    .keyboardShortcut(.defaultAction)
                    .disabled(kind.isEmpty || problem != nil)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Why the typed Kind cannot be a Card's; nil while it is empty or fine.
    private var problem: String? {
        guard !kind.isEmpty else { return nil }
        guard let parsed = Kind(kind), parsed != .any else {
            return "Each segment needs at least one character, with no spaces or *."
        }
        if parsed.isReservedForAuthoring {
            return "authoring is reserved for the author Act and Verification."
        }
        return nil
    }

    private func addIfValid() {
        guard !kind.isEmpty, problem == nil else { return }
        add(kind)
        dismiss()
    }
}
