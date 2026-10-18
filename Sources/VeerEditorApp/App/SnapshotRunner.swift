import AppKit
import SwiftUI
import VeerCore

/// Development-only visual verification. With `VEER_SNAPSHOT_DIR` set, the app walks through
/// scripted states on an isolated in-memory store and writes window PNGs, then quits.
@MainActor
enum SnapshotRunner {
    static func startIfRequested(store: EditorStore) {
        guard let path = ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances: [(String, NSAppearance.Name)] = (ProcessInfo.processInfo.environment["VEER_SNAPSHOT_APPEARANCE"] ?? "light,dark")
            .split(separator: ",").map { $0 == "dark" ? ("dark", .darkAqua) : ("light", .aqua) }
        Task { @MainActor in
            for (label, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                await run(store: store, into: directory, suffix: label)
            }
            NSApp.terminate(nil)
        }
    }

    static func run(store: EditorStore, into directory: URL, suffix: String) async {
        func shot(_ name: String, size: CGSize = Metrics.defaultWindow) async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.attachedSheet == nil || $0.sheets.isEmpty == false }) ?? NSApp.mainWindow else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(size)
            await settle(0.6)
            capture(window, to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            if let sheet = window.attachedSheet {
                capture(sheet, to: directory.appendingPathComponent("\(name)-sheet-\(suffix).png"))
            }
        }

        store.deleteAllSessions()
        store.useAI = false
        store.inspectorPresented = true
        await shot("01-start")

        store.loadSample()
        await shot("02-exits")

        store.confirmExits()
        await shot("03-empty")

        store.composerText = "YouTube 走 @"
        store.composerFocusToken += 1
        await shot("04-mention")
        store.composerText = ""

        store.send("Netflix 走日本，ChatGPT 走美国")
        await settle(0.25)
        await shot("05-running")
        await waitIdle(store)
        await shot("06-review")

        if let turn = store.current?.turns.last, let first = turn.proposal?.items.last {
            store.setAccepted(false, item: first.id, turnID: turn.id)
            await settle(0.3)
            await shot("07a-revalidating")
            for _ in 0..<200 where !store.revalidating.isEmpty { await settle(0.1) }
            await shot("07-partial")
            store.setAccepted(true, item: first.id, turnID: turn.id)
            for _ in 0..<200 where !store.revalidating.isEmpty { await settle(0.1) }
        }

        store.write()
        await shot("08-written")

        store.inspectorTab = .rules
        await shot("09-rules")
        store.inspectorTab = .test
        store.testQuery = "www.netflix.com"
        await shot("10-test")
        store.inspectorTab = .exits
        await shot("11-exits-tab")
        store.inspectorTab = .changes
        store.diffScope = .original
        await shot("12-diff-original")
        store.diffScope = .turn

        store.send("YouTube 走代理")
        await waitIdle(store)
        store.send("节点太卡了换一个")
        await waitIdle(store)
        await shot("13-clarify-scope")

        store.useAI = true
        store.settings = AISettings(preset: .deepSeek)
        store.sessionKey = "sk-snapshot-invalid"
        store.settings.baseURL = "https://127.0.0.1:9/v1"
        store.send("Telegram 走香港")
        await waitIdle(store)
        await shot("14-ai-failure")
        store.useAI = false
        store.sessionKey = nil

        store.send("Spotify 走美国")
        await waitIdle(store)
        store.undo()
        await shot("15-stale-after-undo")

        store.payloadTurnID = store.current?.turns.first { $0.sentPayload != nil }?.id
        await shot("16-payload")
        store.payloadTurnID = nil
        await settle(0.4)

        store.showingExportSheet = true
        await shot("17-export")
        store.showingExportSheet = false
        await settle(0.4)

        store.inspectorPresented = true
        await shot("18-minimum", size: Metrics.minWindow)

        store.showingSubscriptionSheet = true
        await settle(0.3)
        store.importError = "链接返回了重定向，Veer 不会自动跟随。请使用最终地址。"
        await shot("19-subscription")
        store.showingSubscriptionSheet = false
        store.importError = nil
        await settle(0.4)
        let links = [
            "trojan://pw@jp.example.invalid:443?sni=jp.example.invalid#🇯🇵 东京 Trojan",
            "hysteria2://auth@hk.example.invalid:443?sni=hk.example.invalid#🇭🇰 香港 Hy2",
            "vless://11111111-1111-1111-1111-111111111111@us.example.invalid:443?security=tls&type=ws&path=%2Fws#🇺🇸 美国 VLESS",
            "wireguard://key@wg.example.invalid:51820#WG",
        ].joined(separator: "\n")
        store.importText(Data(links.utf8).base64EncodedString())
        await shot("21-base64-import")
        store.newImport()
        await shot("20-start-with-sessions")
        store.select(store.sessions[0].id)
        await settle(0.3)
    }

    static func waitIdle(_ store: EditorStore) async {
        for _ in 0..<300 where store.isRunning { await settle(0.1) }
        await settle(0.4)
    }

    static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Window-server image of one of our own windows (includes glass and materials). Looked up
    /// dynamically because the API is deprecated; capturing the app's own windows needs no
    /// screen-recording permission. Falls back to drawing the view hierarchy.
    static func capture(_ window: NSWindow, to url: URL) {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // optionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
            if let image = function(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
