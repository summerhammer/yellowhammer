#if DEBUG
import Domain
import Pulse
import SwiftUI

/// The prototype's crucial colours — eight, and no more. Brand is unfilled, so the defaults are system
/// colours; the Playground edits these live so a variant's colour weight can be judged before any brand
/// value exists. Every other colour a variant uses is a semantic system style (`.primary`, `.secondary`,
/// `.separator`, materials).
struct PulsePalette: Equatable {
    /// Links, selection and the window tint.
    var accent: Color = .accentColor
    /// Needs you and Waiting on You.
    var needsYou: Color = .orange
    /// Blocked Cards and blocked Repo Lanes.
    var blocked: Color = .red
    /// `working`, running Attempts and running lanes.
    var working: Color = .green
    /// Landed lanes, Done Cards and merged pull requests.
    var landed: Color = .purple
    /// Tonight / last Night.
    var night: Color = .indigo
    /// `yh doctor` Health flags.
    var health: Color = .yellow
    /// The fill behind tiles and boxed groups. A translucent primary, so it adapts to light and dark.
    var surface: Color = .primary.opacity(0.05)
}

/// Starting points for the Playground's colour controls.
enum PulsePalettePreset: String, CaseIterable, Identifiable {
    case system = "System"
    case muted = "Muted"
    case monochrome = "Monochrome"

    var id: Self { self }

    var palette: PulsePalette {
        switch self {
        case .system:
            PulsePalette()
        case .muted:
            PulsePalette(
                accent: .accentColor,
                needsYou: .orange.mix(with: .gray, by: 0.35),
                blocked: .red.mix(with: .gray, by: 0.35),
                working: .teal.mix(with: .gray, by: 0.25),
                landed: .purple.mix(with: .gray, by: 0.35),
                night: .indigo.mix(with: .gray, by: 0.35),
                health: .brown,
                surface: .primary.opacity(0.05)
            )
        case .monochrome:
            PulsePalette(
                accent: .accentColor,
                needsYou: .primary,
                blocked: .primary,
                working: .secondary,
                landed: .secondary,
                night: .secondary,
                health: .primary,
                surface: .primary.opacity(0.05)
            )
        }
    }
}

extension EnvironmentValues {
    /// The palette every composed variant reads. The Playground overrides it; the Gallery uses the default.
    @Entry var pulsePalette = PulsePalette()
}

// MARK: - State colours

extension PulsePalette {
    func color(for status: ProjectStatus) -> Color {
        status == .working ? working : .secondary
    }

    func color(for state: LaneState) -> Color {
        switch state {
        case .running: working
        case .blocked: blocked
        case .waitingOnYou: needsYou
        case .landed: landed
        case .idle: .secondary
        }
    }

    func color(for state: CardState) -> Color {
        switch state {
        case .inProgress: working
        case .done: landed
        case .blocked: blocked
        case .waitingOnYou: needsYou
        case .todo, .cancelled: .secondary
        }
    }

    /// A nil roll-up state (the Journal cannot compute it) has no colour of its own.
    func color(for state: RollUpState?) -> Color {
        guard let state else { return .secondary }
        return switch state {
        case .authoring: .secondary
        case .running: working
        case .needsYou, .partialLanding: needsYou
        case .blocked: blocked
        case .verified: landed
        }
    }

    /// A nil pull request state (it lives in GitHub) has no colour of its own.
    func color(for state: PullRequestState?) -> Color {
        guard let state else { return .secondary }
        return switch state {
        case .open: working
        case .draft: .secondary
        case .merged: landed
        case .closed: blocked
        }
    }

    func color(for state: NightPulseState) -> Color {
        switch state {
        case .running: working
        case .done: night
        case .starved: needsYou
        case .halted: blocked
        }
    }

    func color(for group: PulseGroup) -> Color {
        switch group {
        case .needsYou: needsYou
        case .now: working
        case .feature: accent
        case .night: night
        case .health: health
        }
    }
}

// MARK: - Playground controls

/// The eight crucial colours. The Baseline ignores them; every composed variant reads them.
struct PulsePaletteControls: View {
    @Binding var palette: PulsePalette
    @Binding var preset: PulsePalettePreset

    var body: some View {
        Section("Colors") {
            Picker("Preset", selection: $preset) {
                ForEach(PulsePalettePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: preset) { _, newValue in palette = newValue.palette }
            ColorPicker("Accent", selection: $palette.accent, supportsOpacity: false)
            ColorPicker("Needs you", selection: $palette.needsYou, supportsOpacity: false)
            ColorPicker("Blocked", selection: $palette.blocked, supportsOpacity: false)
            ColorPicker("Working", selection: $palette.working, supportsOpacity: false)
            ColorPicker("Landed", selection: $palette.landed, supportsOpacity: false)
            ColorPicker("Night", selection: $palette.night, supportsOpacity: false)
            ColorPicker("Health", selection: $palette.health, supportsOpacity: false)
            ColorPicker("Surface", selection: $palette.surface)
            Button("Reset to Preset") { palette = preset.palette }
        }
    }
}
#endif
