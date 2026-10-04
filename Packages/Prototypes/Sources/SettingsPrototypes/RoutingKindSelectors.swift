#if DEBUG
import SwiftUI

// Two ways to choose a Card's Kind, one per variant:
//
// - `popUp` — a pop-up button listing every known Kind, indented by depth, and "New Kind…" for one the
//   list lacks (H + I).
// - `path` — the Kind as the dotted path it is, one chip per segment, like Finder's path bar: each chip
//   swaps that segment for a sibling, and "+" goes one level deeper (H + J).
//
// Neither offers the reserved authoring Kind: the author Act and Verification have sections of their own.

enum KindSelectorStyle {
    case popUp, path
}

struct KindSelector: View {
    /// What the selector chooses for.
    enum Purpose {
        /// A Routing Entry's Kind, where Any Kind is a choice.
        case entry
        /// The Kind of the Card "Test a Card" imagines, which always has one.
        case question
    }

    @Binding var value: String
    let style: KindSelectorStyle
    let purpose: Purpose
    let knownKinds: [String]

    var body: some View {
        switch style {
        case .popUp:
            KindPopUp(value: $value, purpose: purpose, kinds: Self.cardKinds(knownKinds))
        case .path:
            KindPath(value: $value, purpose: purpose, kinds: Self.cardKinds(knownKinds))
        }
    }

    /// The Kinds a Card can carry: every known Kind but the reserved one.
    static func cardKinds(_ known: [String]) -> [String] {
        known.filter { $0.split(separator: ".").first != "authoring" }
    }

    static func title(of value: String) -> String {
        value.isEmpty || value == "*" ? "Any Kind" : value
    }
}

// MARK: - I · Pop-up

private struct KindPopUp: View {
    @Binding var value: String
    let purpose: KindSelector.Purpose
    let kinds: [String]
    @State private var isAddingKind = false

    var body: some View {
        Menu {
            if purpose == .entry {
                choice("", title: "Any Kind")
                Divider()
            }
            ForEach(kinds, id: \.self) { kind in
                choice(kind, title: indented(kind))
            }
            Divider()
            Button("New Kind\u{2026}") { isAddingKind = true }
        } label: {
            Text(KindSelector.title(of: value))
                .font(value.isEmpty ? .body : .body.monospaced())
        }
        .menuStyle(.button)
        .fixedSize()
        .popover(isPresented: $isAddingKind, arrowEdge: .bottom) {
            NewKindPopover(parent: "") { value = $0 }
        }
    }

    /// A Kind with one indent per level, so `impl.boilerplate` sits under `impl`.
    private func indented(_ kind: String) -> String {
        let depth = kind.split(separator: ".").count - 1
        return String(repeating: "    ", count: depth) + (kind.split(separator: ".").last.map(String.init) ?? kind)
    }

    private func choice(_ kind: String, title: String) -> some View {
        Button {
            value = kind
        } label: {
            if value == kind {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - J · Path

private struct KindPath: View {
    @Binding var value: String
    let purpose: KindSelector.Purpose
    let kinds: [String]
    @State private var addingUnder: String?

    private var segments: [String] {
        value.isEmpty || value == "*" ? [] : value.split(separator: ".").map(String.init)
    }

    var body: some View {
        HStack(spacing: 3) {
            rootChip
            ForEach(segments.indices.dropFirst(), id: \.self) { level in
                separator
                segmentChip(level: level)
            }
            if !(purpose == .question && segments.isEmpty) {
                deeperChip
            }
        }
        .popover(isPresented: Binding { addingUnder != nil } set: { if !$0 { addingUnder = nil } }) {
            NewKindPopover(parent: addingUnder ?? "") { value = $0 }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
    }

    /// The first segment, or Any Kind.
    private var rootChip: some View {
        Menu {
            if purpose == .entry {
                choice("", title: "Any Kind")
            }
            Section("Kinds") {
                ForEach(children(of: []), id: \.self) { root in
                    choice(root, title: root)
                }
            }
            Divider()
            Button("New Kind\u{2026}") { addingUnder = "" }
        } label: {
            chipLabel(segments.first ?? KindSelector.title(of: value), monospaced: !segments.isEmpty)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A deeper segment: its siblings, or stop one level up.
    private func segmentChip(level: Int) -> some View {
        let parent = Array(segments.prefix(level))
        return Menu {
            ForEach(children(of: parent), id: \.self) { sibling in
                choice((parent + [sibling]).joined(separator: "."), title: sibling)
            }
            Divider()
            Button("Stop at \(parent.joined(separator: "."))") { value = parent.joined(separator: ".") }
        } label: {
            chipLabel(segments[level], monospaced: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "+": one level deeper — a known child, or a new one.
    private var deeperChip: some View {
        Menu {
            let known = children(of: segments)
            if !known.isEmpty {
                Section(segments.isEmpty ? "Kinds" : "Under \(value)") {
                    ForEach(known, id: \.self) { child in
                        choice((segments + [child]).joined(separator: "."), title: child)
                    }
                }
            }
            Button(segments.isEmpty ? "New Kind\u{2026}" : "New Kind under \(value)\u{2026}") { addingUnder = value }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.05), in: .circle)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Narrow to a deeper Kind")
    }

    private func chipLabel(_ text: String, monospaced: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).font(monospaced ? .body.monospaced() : .body)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.background, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
        .contentShape(.capsule)
    }

    /// The known next segments under `parent`.
    private func children(of parent: [String]) -> [String] {
        kinds
            .map { $0.split(separator: ".").map(String.init) }
            .filter { $0.count > parent.count && $0.starts(with: parent) }
            .map { $0[parent.count] }
            .uniqued()
    }

    private func choice(_ kind: String, title: String) -> some View {
        Button {
            value = kind
        } label: {
            if value == kind {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - A new Kind

/// One new segment under `parent`, typed: the dotted path is built, not typed.
struct NewKindPopover: View {
    let parent: String
    let add: (String) -> Void
    @State private var segment = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Kind").font(.headline)
            HStack(spacing: 2) {
                if !parent.isEmpty {
                    Text("\(parent).").font(.body.monospaced()).foregroundStyle(.secondary)
                }
                TextField("Segment", text: $segment, prompt: Text(parent.isEmpty ? "impl" : "boilerplate"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .labelsHidden()
            }
            Text("One word, no dots or spaces. Cards whose Kind starts with it will match.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Add") {
                    add(parent.isEmpty ? segment : "\(parent).\(segment)")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(segment.isEmpty || segment.contains(".") || segment.contains(" ") || segment.contains("*"))
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

#endif
