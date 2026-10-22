import AppKit
import VeerCore

/// Development-only performance check. With `VEER_PROFILE_SESSIONS` set to a folder of saved
/// sessions (use a copy: the app may save to it), the app loads them with in-memory keys and
/// preferences, switches between them `VEER_PROFILE_ROUNDS` times (default 3), prints how long
/// each switch takes on the main thread, then quits. `VEER_PROFILE_CONFIRMED=1` skips sessions
/// still confirming exits; `VEER_PROFILE_ONLY` takes comma-separated session id prefixes.
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
                }
            }
            NSApp.terminate(nil)
        }
    }
}
