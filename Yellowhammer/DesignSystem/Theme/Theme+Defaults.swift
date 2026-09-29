import SwiftUI
import ThemeKit

nonisolated extension Theme {
    static let `default` = Theme(
        colors: .`default`,
        gradients: .`default`
    )
}

// MARK: - ThemeColors

// Anchor colours from the spec's brand colours (`docs/brand/colors.md`). `attention` (magenta) is
// the spec's proposal, still awaiting sponsor confirmation. `neutral` is the Apple system gray and
// `surface` is primary at 5%; the spec gives both as rules, not hexes.
nonisolated extension ThemeColors {
    static let `default` = ThemeColors(
        brand:       .init(light: Color(hex: 0xF4C900), dark: Color(hex: 0xFFD426)),
        accent:      .init(light: Color(hex: 0xA8481B), dark: Color(hex: 0xEE8C5F)),
        onAccent:    .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        attention:   .init(light: Color(hex: 0xC2278F), dark: Color(hex: 0xFF6BC1)),
        onAttention: .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        active:      .init(light: Color(hex: 0x1A7F37), dark: Color(hex: 0x30D158)),
        onActive:    .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        success:     .init(light: Color(hex: 0x7541CC), dark: Color(hex: 0xB98CFF)),
        onSuccess:   .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        info:        .init(light: Color(hex: 0x4649C8), dark: Color(hex: 0x8285FF)),
        onInfo:      .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        warning:     .init(light: Color(hex: 0xF28C00), dark: Color(hex: 0xFF9F0A)),
        onWarning:   .init(light: Color(hex: 0x16120C), dark: Color(hex: 0x16120C)),
        error:       .init(light: Color(hex: 0xD3302A), dark: Color(hex: 0xFF5A50)),
        onError:     .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x16120C)),
        neutral:     .init(light: Color(hex: 0x8E8E93), dark: Color(hex: 0x98989D)),
        surface:     .init(light: Color(hex: 0x000000).opacity(0.05), dark: Color(hex: 0xFFFFFF).opacity(0.05))
    )
}

// MARK: - ThemeGradients

// The spec leaves gradients to Claude Design; until those land, each is its anchor washed from 32% to
// 8% opacity — the ramp the Hero Rail banner uses.
nonisolated extension ThemeGradients {
    static let `default` = ThemeGradients(
        accentGradient:    .init(
            light: .init(colors: [Color(hex: 0xA8481B).opacity(0.32), Color(hex: 0xA8481B).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0xEE8C5F).opacity(0.32), Color(hex: 0xEE8C5F).opacity(0.08)])
        ),
        activeGradient:    .init(
            light: .init(colors: [Color(hex: 0x1A7F37).opacity(0.32), Color(hex: 0x1A7F37).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0x30D158).opacity(0.32), Color(hex: 0x30D158).opacity(0.08)])
        ),
        attentionGradient: .init(
            light: .init(colors: [Color(hex: 0xC2278F).opacity(0.32), Color(hex: 0xC2278F).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0xFF6BC1).opacity(0.32), Color(hex: 0xFF6BC1).opacity(0.08)])
        ),
        infoGradient:      .init(
            light: .init(colors: [Color(hex: 0x4649C8).opacity(0.32), Color(hex: 0x4649C8).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0x8285FF).opacity(0.32), Color(hex: 0x8285FF).opacity(0.08)])
        ),
        warningGradient:   .init(
            light: .init(colors: [Color(hex: 0xF28C00).opacity(0.32), Color(hex: 0xF28C00).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0xFF9F0A).opacity(0.32), Color(hex: 0xFF9F0A).opacity(0.08)])
        )
    )
}
