/// Where the Settings window has been, and where back and forward lead. The history is the one source of
/// truth for the current section: the sidebar's selection is derived from `current`, so moving back or
/// forward changes only `index` and never records a visit of its own.
struct SettingsHistory: Equatable {
    private(set) var entries: [SettingsSection] = [.general]
    private(set) var index = 0

    var current: SettingsSection { entries[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// Goes to `section`. Whatever lay ahead of the current entry is dropped, as in a browser. Visiting
    /// the section already shown records nothing.
    mutating func visit(_ section: SettingsSection) {
        guard section != current else { return }
        entries.removeSubrange((index + 1)...)
        entries.append(section)
        index += 1
    }

    mutating func back() {
        if canGoBack { index -= 1 }
    }

    mutating func forward() {
        if canGoForward { index += 1 }
    }
}
