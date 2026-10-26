// Captures the landing page's app screenshots (S1, S2, S4 in the web repo's `astro/SCREENSHOTS.md`) in light
// and dark: writes the showcase Journals, launches a Debug build of the app once per shot with the DEBUG-only
// showcase arguments, waits for the window to report the state it was asked for, checks it, and captures the
// window with `screencapture`.
//
//     landing-screenshots --app <Yellowhammer.app> --output <dir> [--any-time]
//
// Run between 06:00 and 22:00 local: the example Project's Night window is 22:00–06:00, and inside it the
// Pulse shows the open window instead of last night. `--any-time` skips that check, for trying the tool out.
//
// `scripts/landing-screenshots.sh` builds the app and runs this. The terminal needs the Screen Recording
// permission, and Automation for System Events (to bring the window to the front), each granted once.

import AppKit
import CoreGraphics
import Foundation
import Showcase

struct Failure: Error, CustomStringConvertible {
    let description: String
}

struct Shot {
    let saveAs: String
    let configuration: String
    /// Window content size in points; the PNG is twice this.
    let width: Int
    let height: Int
    let inspect: String?
    let hide: String?
    let title: String
    let lineContains: String
}

let shots = [
    Shot(
        saveAs: "pulse-night-done", configuration: "morning", width: 1280, height: 880, inspect: nil,
        hide: "inspector", title: "Night done", lineContains: "18 clauses met"
    ),
    Shot(
        saveAs: "night-account", configuration: "morning", width: 1280, height: 860, inspect: "night",
        hide: nil, title: "Night done", lineContains: "18 clauses met"
    ),
    Shot(
        saveAs: "pulse-attempts", configuration: "working", width: 960, height: 680,
        inspect: "attempt:\(Showcase.retriedAttemptID)", hide: "sidebar", title: "Working",
        lineContains: "3 Attempts running"
    )
]

func value(of option: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
        throw Failure(description: "usage: landing-screenshots --app <Yellowhammer.app> --output <dir>")
    }
    return arguments[index + 1]
}

/// Waits for `file` to exist, up to `timeout` seconds.
func waitForFile(_ file: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return false
}

/// The app's main window: its on-screen, normal-layer window with the largest area.
func mainWindow(of pid: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    return list.compactMap { info -> (CGWindowID, CGRect)? in
        guard info[kCGWindowOwnerPID as String] as? pid_t == pid, info[kCGWindowLayer as String] as? Int == 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo)
        else { return nil }
        return (id, bounds)
    }
    .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let command = ([executable] + arguments).joined(separator: " ")
        throw Failure(description: "\(command) exited \(process.terminationStatus)")
    }
}

/// Launches this exact bundle frontmost, as the Dock would: a child process of a terminal cannot activate
/// itself, and an inactive window is captured with grey controls.
func launch(_ app: URL, arguments: [String]) throws -> NSRunningApplication {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.activates = true
    configuration.createsNewApplicationInstance = true
    configuration.addsToRecentItems = false
    nonisolated(unsafe) var result: Result<NSRunningApplication, Error>?
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
        result = running.map { .success($0) } ?? .failure(error ?? Failure(description: "\(app.path) did not launch"))
        done.signal()
    }
    done.wait()
    guard let result else { throw Failure(description: "\(app.path) did not launch") }
    return try result.get()
}

/// Quits the app and waits for it to go, so the next launch is a fresh instance.
func quit(_ running: NSRunningApplication) {
    running.terminate()
    let deadline = Date().addingTimeInterval(10)
    while !running.isTerminated, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !running.isTerminated { running.forceTerminate() }
}

func pixelSize(of png: URL) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return (image.width, image.height)
}

func capture(_ shot: Shot, appearance: String, app: URL, showcase: URL, output: URL) throws {
    let name = "\(shot.saveAs)-\(appearance)"
    let ready = showcase.appending(component: "\(name).ready")
    try? FileManager.default.removeItem(at: ready)
    var arguments = [
        "-YellowhammerConfigurationDirectory",
        showcase.appending(component: shot.configuration).path(percentEncoded: false),
        // Answers `yh doctor --json` with no findings, so Health reads "No flags", and runs nothing else.
        "-YellowhammerEngineStub", showcase.appending(component: "yh-stub.sh").path(percentEncoded: false),
        // No "Yellowhammer moved" alert over the window, whatever this Mac's /usr/local/bin/yh is.
        "-YellowhammerCommandLineToolLink", showcase.appending(component: "no-yh-link").path(percentEncoded: false),
        "-YellowhammerWindowContentSize", "\(shot.width)x\(shot.height)",
        "-YellowhammerAppearance", appearance,
        "-YellowhammerShowcaseProject", "orbit",
        "-YellowhammerShowcaseReady", ready.path(percentEncoded: false),
        "-ApplePersistenceIgnoreState", "YES"
    ]
    if let inspect = shot.inspect { arguments += ["-YellowhammerShowcaseInspect", inspect] }
    if let hide = shot.hide { arguments += ["-YellowhammerShowcaseHide", hide] }

    let running = try launch(app, arguments: arguments)
    defer { quit(running) }

    guard waitForFile(ready, timeout: 30) else { throw Failure(description: "\(name): the window never got ready") }
    let state = try String(contentsOf: ready, encoding: .utf8).split(separator: "\n").map(String.init)
    guard state.first == shot.title, state.dropFirst().first?.contains(shot.lineContains) == true else {
        throw Failure(description: "\(name): the Pulse reads \(state), not \(shot.title) / \(shot.lineContains)")
    }
    // Frontmost, so the window is captured active. A launch's own activation is refused whenever another
    // app holds focus (a notification alert does); System Events is not.
    try run("/usr/bin/osascript", [
        "-e",
        "tell application \"System Events\" to set frontmost of (first process whose unix id is "
            + "\(running.processIdentifier)) to true"
    ])
    // The Night's account and the Inspector read off the main actor; the Mist animates in.
    Thread.sleep(forTimeInterval: 2)

    guard let window = mainWindow(of: running.processIdentifier) else {
        throw Failure(description: "\(name): no window on screen")
    }
    guard Int(window.bounds.width) == shot.width, Int(window.bounds.height) == shot.height else {
        throw Failure(description: "\(name): the window is \(window.bounds.size), not \(shot.width)x\(shot.height)")
    }
    // The pointer off the window, so no hover state shows.
    let screen = CGDisplayBounds(CGMainDisplayID())
    CGWarpMouseCursorPosition(CGPoint(x: screen.maxX - 2, y: screen.maxY - 2))
    Thread.sleep(forTimeInterval: 1)

    let png = output.appending(component: "\(name).png")
    // -o: no shadow; -x: no sound. The window's own pixels, at the display's scale.
    try run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(window.id), png.path(percentEncoded: false)])
    guard let size = pixelSize(of: png), size == (shot.width * 2, shot.height * 2) else {
        throw Failure(description: "\(name): captured \(String(describing: pixelSize(of: png))), not 2x — Retina?")
    }
    print(png.path(percentEncoded: false))
}

do {
    let arguments = CommandLine.arguments
    let app = URL(filePath: try value(of: "--app", in: arguments), directoryHint: .isDirectory)
    let output = URL(filePath: try value(of: "--output", in: arguments), directoryHint: .isDirectory)
    // The example Night is 22:00–06:00 and closed at 06:00 today; inside a Night window the Pulse shows that
    // window instead of the finished Night.
    let hour = Calendar.current.component(.hour, from: Date())
    guard (6..<22).contains(hour) || arguments.contains("--any-time") else {
        throw Failure(description: "run between 06:00 and 22:00 local, when the example Night reads as last night")
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let showcase = FileManager.default.temporaryDirectory
        .appending(component: "yh-landing-showcase-\(UUID().uuidString)", directoryHint: .isDirectory)

    // Written just before the launches: the `working` Journal's Act Lease lasts ten minutes, and the Pulse
    // shows times relative to now.
    let now = Date()
    try Showcase.write(to: showcase, now: now)
    try Showcase.verify(directory: showcase, now: now)
    try Data("#!/bin/sh\nif [ \"$1\" = doctor ] && [ \"$2\" = --json ]; then echo '[]'; fi\nexit 0\n".utf8)
        .write(to: showcase.appending(component: "yh-stub.sh"))

    for shot in shots {
        for appearance in ["light", "dark"] {
            try capture(shot, appearance: appearance, app: app, showcase: showcase, output: output)
        }
    }
    try? FileManager.default.removeItem(at: showcase)
} catch {
    FileHandle.standardError.write(Data("landing-screenshots: \(error)\n".utf8))
    exit(1)
}
