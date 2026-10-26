import AppKit
import SwiftUI

/// The main window's default size: room for the three columns at their ideal widths.
///
/// A DEBUG build takes another from the launch argument `-YellowhammerWindowContentSize <w>x<h>` (points), so
/// the landing-page screenshot tool (`Tools/LandingScreenshots`) can capture the window at the size each slot
/// needs. Only the argument domain is read, so it cannot persist through `defaults write`.
enum MainWindowSize {
    static let argument = "YellowhammerWindowContentSize"

    static let standard = CGSize(width: 1180, height: 760)

    /// The size the launch argument asks for; nil in Release, or when no valid one was given.
    static var override: CGSize? {
#if DEBUG
        guard let value = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[argument]
            as? String
        else { return nil }
        return parse(value)
#else
        return nil
#endif
    }

    /// `1280x880` as a size; nil for anything else.
    static func parse(_ value: String) -> CGSize? {
        let parts = value.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

extension View {
    /// Under the launch argument, sizes the hosting window's content to it and centres the window, once, when
    /// the view first joins it. A frame AppKit autosaved earlier wins over `.defaultSize`, so the size is set
    /// on the window itself.
    @ViewBuilder
    func mainWindowSizeOverride() -> some View {
        if let size = MainWindowSize.override {
            background(WindowSizer(size: size))
        } else {
            self
        }
    }
}

private struct WindowSizer: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> SizingView {
        SizingView(size: size)
    }

    func updateNSView(_ nsView: SizingView, context: Context) {}

    final class SizingView: NSView {
        private let size: CGSize
        private var applied = false

        init(size: CGSize) {
            self.size = size
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !applied, let window else { return }
            applied = true
            // After SwiftUI's own first layout, which would otherwise size the window back, and again while a
            // hidden sidebar's smaller minimum settles. Never below the columns' current minimum: AppKit loops
            // on the split view's constraints until it throws.
            for delay in [0, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [size] in
                    let minimum = window.contentMinSize
                    window.setContentSize(CGSize(
                        width: max(size.width, minimum.width), height: max(size.height, minimum.height)
                    ))
                    window.center()
                }
            }
        }
    }
}
