#if DEBUG
import Domain
import Pulse
import SwiftUI

// The backgrounds the status heads draw their colour with; see `PulseStatusHead`.

/// A pixelated gradient: square cells, mostly the first colour, sprinkled with the others, that thin out
/// and fade from the top-trailing corner, so the headline at the leading edge sits on a calm field.
/// The pattern is a fixed hash of each cell, so it renders the same every time.
struct PulsePixelField: View {
    let colors: [Color]
    var cell: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                let down = Double(row) / Double(max(rows - 1, 1))
                for column in 0..<columns {
                    let across = Double(column) / Double(max(columns - 1, 1))
                    let fade = max(0, 1 - down * 0.85 - (1 - across) * 0.75)
                    let dither = Self.hash(column, row, salt: 1)
                    // Fewer cells survive further down, so the field dissolves rather than dims.
                    guard dither < fade * 1.15 else { continue }
                    let pick = Self.hash(column, row, salt: 2)
                    let color = pick < 0.9 ? colors[0] : colors[min(pick < 0.96 ? 1 : 2, colors.count - 1)]
                    let opacity = 0.1 + 0.5 * fade * (0.5 + 0.5 * Self.hash(column, row, salt: 3))
                    let rect = CGRect(
                        x: CGFloat(column) * cell + 1, y: CGFloat(row) * cell + 1, width: cell - 2, height: cell - 2
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(opacity)))
                }
            }
        }
    }

    private static func hash(_ column: Int, _ row: Int, salt: UInt64) -> Double {
        var value = UInt64(truncatingIfNeeded: column) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(truncatingIfNeeded: row) &* 0xC2B2_AE3D_27D4_EB4F
        value ^= salt &* 0x1656_67B1_9E37_79F9
        value ^= value >> 29
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 32
        return Double(value & 0xFFFF) / Double(0xFFFF)
    }
}

/// A mesh of the status colour and its two neighbours, fading to nothing at the bottom edge.
/// Mist, in light appearance, is about half as strong, fades out sooner, and keeps the colour away
/// from the leading edge where the headline sits. In dark appearance it is the Aurora.
struct PulseMesh: View {
    let color: Color
    let companions: [Color]
    var isMist = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let first = companions.first ?? color
        let second = companions.last ?? color
        if isMist, colorScheme == .light {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.55, 0], [1, 0],
                    [0, 0.45], [0.72, 0.32], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: [
                    color.opacity(0.22), first.opacity(0.2), color.opacity(0.28),
                    color.opacity(0.08), color.opacity(0.18), second.opacity(0.16),
                    color.opacity(0), first.opacity(0), color.opacity(0)
                ]
            )
        } else {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.68, 0.38], [1, 0.55],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: [
                    color.opacity(0.55), first.opacity(0.4), color.opacity(0.5),
                    color.opacity(0.35), color.opacity(0.42), second.opacity(0.32),
                    color.opacity(0), first.opacity(0), color.opacity(0)
                ]
            )
        }
    }
}

/// A horizontal gradient whose stops are each state's share, fading downward. With no tally it is the
/// status colour alone.
struct PulseSpectrum: View {
    let tallies: [PulseTally]
    let fallback: Color

    var body: some View {
        // Only the coloured states make bands; To do stays in the legend, so grey never dilutes the status.
        let tallies = tallies.filter { $0.label != "To do" }
        let total = Double(tallies.reduce(0) { $0 + $1.count })
        var stops: [Gradient.Stop] = []
        var start = 0.0
        for tally in tallies {
            let end = start + Double(tally.count) / total
            // Two stops a little inside each band, so a band reads as a colour and blends only at its edge.
            let inset = (end - start) * 0.2
            stops.append(.init(color: tally.color.opacity(0.5), location: start + inset))
            stops.append(.init(color: tally.color.opacity(0.5), location: end - inset))
            start = end
        }
        if stops.isEmpty { stops = [.init(color: fallback.opacity(0.35), location: 0)] }
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
    }
}

/// Each tally as a dot, a count and its label.
struct PulseTallyLegend: View {
    let tallies: [PulseTally]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(tallies) { tally in
                HStack(spacing: 5) {
                    Circle().fill(tally.color).frame(width: 8, height: 8)
                    Text("\(tally.count) \(tally.label)").monospacedDigit()
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
#endif
