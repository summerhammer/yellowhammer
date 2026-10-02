import SwiftUI
import ThemeKit

nonisolated extension Theme {
    static let `default` = Theme(
        colors: .`default`,
        gradients: .`default`
    )
}

// MARK: - ThemeColors

// Anchor colours tuned against the Overview window, not the spec's draft values in
// `docs/brand/colors.md`: `accent`, `attention`, `warning` and `error` sit on the Apple system hues,
// `active`, `success` and `info` are tuned in between. The `on…` colours are white, which is low
// contrast on `attention` and `warning`, so every coloured mark sits beside its label. `neutral` is
// the Apple system gray and `surface` is primary at 5%; the spec gives both as rules, not hexes.
nonisolated extension ThemeColors {
    static let `default` = ThemeColors(
        brand:       .init(light: Color(hex: 0xF4C900), dark: Color(hex: 0xFFD426)),
        accent:      .init(light: Color(hex: 0x007AFF), dark: Color(hex: 0x0A84FF)),
        onAccent:    .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        attention:   .init(light: Color(hex: 0xFF9500), dark: Color(hex: 0xFF9F0A)),
        onAttention: .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        active:      .init(light: Color(hex: 0x2EB250), dark: Color(hex: 0x30D158)),
        onActive:    .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        success:     .init(light: Color(hex: 0x71C171), dark: Color(hex: 0x408140)),
        onSuccess:   .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        info:        .init(light: Color(hex: 0x46B8DA), dark: Color(hex: 0x269ABC)),
        onInfo:      .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        warning:     .init(light: Color(hex: 0xFFCC00), dark: Color(hex: 0xFFD60A)),
        onWarning:   .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
        error:       .init(light: Color(hex: 0xFF3B30), dark: Color(hex: 0xFF453A)),
        onError:     .init(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0xFFFFFF)),
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
            light: .init(colors: [Color(hex: 0x007AFF).opacity(0.32), Color(hex: 0x007AFF).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0x0A84FF).opacity(0.32), Color(hex: 0x0A84FF).opacity(0.08)])
        ),
        activeGradient:    .init(
            light: .init(colors: [Color(hex: 0x2EB250).opacity(0.32), Color(hex: 0x2EB250).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0x30D158).opacity(0.32), Color(hex: 0x30D158).opacity(0.08)])
        ),
        attentionGradient: .init(
            light: .init(colors: [Color(hex: 0xFF9500).opacity(0.32), Color(hex: 0xFF9500).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0xFF9F0A).opacity(0.32), Color(hex: 0xFF9F0A).opacity(0.08)])
        ),
        infoGradient:      .init(
            light: .init(colors: [Color(hex: 0x46B8DA).opacity(0.32), Color(hex: 0x46B8DA).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0x269ABC).opacity(0.32), Color(hex: 0x269ABC).opacity(0.08)])
        ),
        warningGradient:   .init(
            light: .init(colors: [Color(hex: 0xFFCC00).opacity(0.32), Color(hex: 0xFFCC00).opacity(0.08)]),
            dark:  .init(colors: [Color(hex: 0xFFD60A).opacity(0.32), Color(hex: 0xFFD60A).opacity(0.08)])
        )
    )
}
