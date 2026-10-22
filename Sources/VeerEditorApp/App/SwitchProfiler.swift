import AppKit
import VeerCore

/// Development-only performance check. With `VEER_PROFILE_SESSIONS` set to a folder of saved
/// sessions (use a copy: the app may save to it), the app loads them with in-memory keys and
/// preferences, switches between them `VEER_PROFILE_ROUNDS` times (default 3), prints how long
/// each switch takes on the main thread, then quits. `VEER_PROFILE_CONFIRMED=1` skips sessions
/// still confirming exits; `VEER_PROFILE_ONLY` takes comma-separated session id prefixes;
/// `VEER_PROFILE_SHOTS` saves a screenshot after each switch; `VEER_PROFILE_SCROLL=top|middle`
/// moves the conversation before each switch and `VEER_PROFILE_WHEEL=<points>` scrolls it up with
/// trackpad-style events after one (checks for the blank-conversation and "回到最新" bugs).
@MainActor
enum SwitchProfiler {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["VEER_PROFILE_SESSIONS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func startIfRequested(store: EditorStore) {
        guard directory != nil else { return }
        let rounds = Int(ProcessInfo.processInfo.environment["VEER_PROFILE_ROUNDS"] ?? "") ?? 3
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let confirmedOnly = ProcessInfo.processInfo.environment["VEER_PROFILE_CONFIRMED"] == "1"
            let only = ProcessInfo.processInfo.environment["VEER_PROFILE_ONLY"]?.split(separator: ",").map(String.init)
            let sessions = store.sessions
                .filter { session in
                    (!confirmedOnly || session.exitsConfirmed)
                        && (only?.contains { session.id.uuidString.hasPrefix($0) } ?? true)
                }
                .map { ($0.id, $0.title, $0.turns.count) }
            print("PROFILE loaded \(sessions.count) sessions")
            for round in 1...rounds {
                for (id, title, turns) in sessions {
                    let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
                    // VEER_PROFILE_SCROLL=top|middle: move the conversation away from the bottom first.
                    if let where_ = ProcessInfo.processInfo.environment["VEER_PROFILE_SCROLL"], let content = window?.contentView {
                        @MainActor func scrollViews(_ view: NSView) -> [NSScrollView] {
                            if let scroll = view as? NSScrollView { return [scroll] }
                            return view.subviews.flatMap(scrollViews)
                        }
                        if let scroll = scrollViews(content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                            let height = scroll.documentView?.frame.height ?? 0
                            let y = where_ == "top" ? 0 : height / 2
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                    let start = CFAbsoluteTimeGetCurrent()
                    store.select(id)
                    window?.contentView?.layoutSubtreeIfNeeded()
                    window?.displayIfNeeded()
                    let applied = CFAbsoluteTimeGetCurrent()
                    // Whatever SwiftUI defers to the next pass of the run loop.
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    window?.contentView?.layoutSubtreeIfNeeded()
                    window?.displayIfNeeded()
                    let settled = CFAbsoluteTimeGetCurrent()
                    print(String(format: "PROFILE round %d | %@ (%d turns) | select+layout %.0f ms | settled %.0f ms",
                                 round, title, turns, (applied - start) * 1000, (settled - start) * 1000))
                    try? await Task.sleep(for: .milliseconds(250))
                    // VEER_PROFILE_WHEEL=<points>: a trackpad-style scroll up in the conversation after the switch.
                    if let amount = ProcessInfo.processInfo.environment["VEER_PROFILE_WHEEL"].flatMap(Int32.init), let window {
                        let point = NSPoint(x: window.frame.width * 0.45, y: window.frame.height * 0.5)
                        let screen = window.convertPoint(toScreen: point)
                        let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                        for (phase, delta) in [(1, 0), (2, amount / 4), (2, amount / 4), (2, amount / 4), (2, amount / 4), (4, 0)] as [(Int64, Int32)] {
                            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { continue }
                            event.location = flipped
                            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                            if let ns = NSEvent(cgEvent: event) { window.sendEvent(ns) }
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    // VEER_PROFILE_SHOTS: a folder for a screenshot after each switch.
                    if let shots = ProcessInfo.processInfo.environment["VEER_PROFILE_SHOTS"], let window {
                        try? await Task.sleep(for: .milliseconds(600))
                        SnapshotRunner.capture(window, to: URL(fileURLWithPath: shots).appendingPathComponent("r\(round)-\(sessions.firstIndex { $0.0 == id } ?? 0)-\(title).png"))
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }
}
