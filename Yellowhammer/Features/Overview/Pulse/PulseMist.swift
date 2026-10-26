import SwiftUI
import ThemeKit

/// The Pulse head's background: a mesh of the status colour and its two neighbours, fading to nothing at the
/// bottom edge. In light appearance it is about half as strong, fades out sooner, and keeps the colour away
/// from the leading edge where the headline sits. While Yellowhammer is working its interior points drift,
/// so a working Project reads at a glance as one; with Reduce Motion on, or at rest, the mist is still.
///
/// Decoration only: the head says the status in words, so colour is never the only signal.
struct PulseMist: View {
    let condition: PulseCondition
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = resolve(condition.token)
        let first = resolve(condition.companions.0)
        let second = resolve(condition.companions.1)
        let isAnimated = condition.isWorking && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimated)) { context in
            let phase = isAnimated ? context.date.timeIntervalSinceReferenceDate : 0
            mesh(color: color, first: first, second: second, phase: phase)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func resolve(_ token: ThemeShapeStyle<Color>) -> Color {
        environment.theme[keyPath: token.keyPath].resolved(in: environment)
    }

    /// The Mesh Mist of the Pulse prototypes, its free points swaying on slow, out-of-step waves. At `phase` 0
    /// it is exactly the still prototype.
    private func mesh(color: Color, first: Color, second: Color, phase: TimeInterval) -> some View {
        let isLight = colorScheme == .light
        let sway = { (period: Double, amplitude: Double) in Float(sin(phase * 2 * .pi / period) * amplitude) }
        let centre: SIMD2<Float> = isLight ? [0.72, 0.32] : [0.68, 0.38]
        let points: [SIMD2<Float>] = [
            [0, 0], [(isLight ? 0.55 : 0.5) + sway(7, 0.18), 0], [1, 0],
            [0, (isLight ? 0.45 : 0.5) + sway(9, 0.12)],
            centre + [sway(5, 0.16), sway(6.5, 0.14)],
            [1, (isLight ? 0.5 : 0.55) + sway(8, 0.14)],
            [0, 1], [0.5 + sway(11, 0.2), 1], [1, 1]
        ]
        let colors: [Color] = if isLight {
            [
                color.opacity(0.22), first.opacity(0.2), color.opacity(0.28),
                color.opacity(0.08), color.opacity(0.18), second.opacity(0.16),
                color.opacity(0), first.opacity(0), color.opacity(0)
            ]
        } else {
            [
                color.opacity(0.55), first.opacity(0.4), color.opacity(0.5),
                color.opacity(0.35), color.opacity(0.42), second.opacity(0.32),
                color.opacity(0), first.opacity(0), color.opacity(0)
            ]
        }
        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }
}
