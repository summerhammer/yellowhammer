#if DEBUG
import Domain
import SwiftUI

// The Inspector layouts; each renders one `PulseInspectorModel`. See `PulseInspectorStyle`.

/// A related item as a row: icon, title and subtitle, and a chevron or an out-arrow.
struct PulseInspectorItemRow: View {
    let item: PulseInspectorModel.Item
    let actions: PulseActions

    var body: some View {
        Button { actions.perform(item.action) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage).foregroundStyle(item.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isOutbound ? "arrow.up.forward" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var isOutbound: Bool {
        if case .open = item.action { return true }
        return false
    }
}

struct PulseInspectorBadges: View {
    let model: PulseInspectorModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.badges.enumerated()), id: \.offset) { _, badge in
                PulseBadge(text: badge.text, color: badge.color)
            }
        }
    }
}

// MARK: - Form

struct PulseFormInspector: View {
    let model: PulseInspectorModel
    let actions: PulseActions

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.kind, systemImage: model.systemImage)
                        .font(.caption)
                        .foregroundStyle(model.tint)
                    Text(model.title).font(.headline)
                    if let identifier = model.identifier {
                        Text(identifier).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    PulseInspectorBadges(model: model)
                }
            }
            Section("Details") {
                ForEach(model.facts, id: \.label) { fact in
                    LabeledContent(fact.label, value: fact.value)
                }
                if let progress = model.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(model.tint)
                }
            }
            ForEach(model.related) { related in
                Section(related.title) {
                    ForEach(related.items) { PulseInspectorItemRow(item: $0, actions: actions) }
                }
            }
            if let primary = model.primary {
                Section {
                    Button(primary.title) { actions.open(primary.destination) }
                } footer: {
                    if let note = model.note { Text(note) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Header and form

/// The header style's large tinted header and pinned prominent way out, with the form style's grouped
/// Details and related sections between them.
struct PulseHeaderFormInspector: View {
    let model: PulseInspectorModel
    let actions: PulseActions

    var body: some View {
        Form {
            Section {
                ForEach(model.facts, id: \.label) { fact in
                    LabeledContent(fact.label, value: fact.value)
                }
                if let progress = model.progress {
                    // A fixed width: a flexible bar in a Form row makes the Inspector column
                    // renegotiate its minimum size without end.
                    LabeledContent("Progress") {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .tint(model.tint)
                            .frame(width: 96)
                    }
                }
            } header: {
                PulseInspectorHeader(model: model)
                    .padding(.bottom, 12)
                    .textCase(nil)
            }
            ForEach(model.related) { related in
                Section(related.title) {
                    ForEach(related.items) { PulseInspectorItemRow(item: $0, actions: actions) }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            if let primary = model.primary {
                VStack(spacing: 6) {
                    Button { actions.open(primary.destination) } label: {
                        Label(primary.title, systemImage: "arrow.up.forward.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let note = model.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// The large header: a tinted icon tile, the kind, the title, the identifier and the badges.
struct PulseInspectorHeader: View {
    let model: PulseInspectorModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.systemImage)
                .font(.title2)
                .foregroundStyle(model.tint)
                .frame(width: 44, height: 44)
                .background(model.tint.opacity(0.14), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.kind.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(model.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let identifier = model.identifier {
                    Text(identifier).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                PulseInspectorBadges(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header

struct PulseHeaderInspector: View {
    let model: PulseInspectorModel
    let actions: PulseActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let progress = model.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .tint(model.tint)
                        Text("\(progress.done) of \(progress.total) Cards done")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(model.facts, id: \.label) { fact in
                        GridRow {
                            Text(fact.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(fact.value).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                ForEach(model.related) { related in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(related.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(related.items) { PulseInspectorItemRow(item: $0, actions: actions) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if let primary = model.primary {
                VStack(spacing: 6) {
                    Button { actions.open(primary.destination) } label: {
                        Label(primary.title, systemImage: "arrow.up.forward.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if let note = model.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        PulseInspectorHeader(model: model)
    }
}

// MARK: - Compact

struct PulseCompactInspector: View {
    let model: PulseInspectorModel
    let actions: PulseActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: model.systemImage).foregroundStyle(model.tint)
                    Text(model.identifier ?? model.kind).font(.callout.monospaced().weight(.semibold))
                    Spacer()
                    Text(model.kind).font(.caption).foregroundStyle(.secondary)
                }
                Text(model.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(model.facts, id: \.label) { fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.label).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(fact.value).multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                }
                ForEach(model.related) { related in
                    Divider()
                    Text(related.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(related.items) { item in
                        Button(item.title) { actions.perform(item.action) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                if let primary = model.primary {
                    Divider()
                    Button(primary.title) { actions.open(primary.destination) }
                        .buttonStyle(.link)
                    if let note = model.note {
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
