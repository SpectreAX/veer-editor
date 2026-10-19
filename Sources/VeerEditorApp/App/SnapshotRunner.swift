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

        store.showingRuleSetSheet = true
        await shot("22-ruleset-sheet")
        store.showingRuleSetSheet = false
        await settle(0.4)
        store.showingOverview = true
        await settle(0.8)
        await shot("23-overview")
        store.showingOverview = false
        await settle(0.4)

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
        store.settings = AISettings(provider: .deepSeek)
        store.sessionKey = "sk-snapshot-invalid"
        store.settings.baseURL = EditorStore.snapshotTestAddress
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
        store.payloadComparing = true
        await settle(1.0)
        await shot("16b-payload-compare")
        store.payloadTurnID = nil
        await settle(0.4)

        store.showingExportSheet = true
        await shot("17-export")
        store.showingExportSheet = false
        await settle(0.4)

        store.inspectorPresented = true
        await shot("18-minimum", size: Metrics.minWindow)

        store.openImport(prefill: "https://sub.example.invalid/api/v1/client/subscribe?token=demo")
        await shot("19-import-input")
        store.importStage = .failed("链接返回了重定向，Veer 不会自动跟随。请使用最终地址。")
        await shot("19b-import-failed")
        store.prepareImport(text: SampleConfig.text, title: SampleConfig.title, source: .sample)
        await shot("19c-import-preview", size: CGSize(width: 1320, height: 900))
        // A multi-protocol subscription, so the charts have several segments.
        var demo: [String] = []
        let regions = ["🇭🇰 香港", "🇯🇵 日本", "🇺🇸 美国", "🇸🇬 新加坡", "🇹🇼 台湾"]
        for i in 0..<36 {
            let name = "\(regions[i % regions.count]) \(String(format: "%02d", i + 1))"
            switch i % 9 {
            case 0, 1, 2, 3: demo.append("ss://\(Data("aes-128-gcm:pw\(i)".utf8).base64EncodedString())@n\(i).example.invalid:8388#\(name)")
            case 4, 5: demo.append("trojan://pw@n\(i).example.invalid:443?sni=n\(i).example.invalid#\(name) Trojan")
            case 6: demo.append("anytls://pw@n\(i).example.invalid:443?sni=n\(i).example.invalid#\(name) AnyTLS")
            case 7: demo.append("vless://11111111-1111-1111-1111-111111111111@n\(i).example.invalid:443?security=tls&type=ws&path=%2F#\(name) VLESS")
            default: demo.append("hysteria2://auth@n\(i).example.invalid:443?sni=n\(i).example.invalid#\(name) Hy2")
            }
        }
        // Notices and a repeated node, removed by the default clean-up.
        demo.insert(contentsOf: ["trojan://pw@info.example.invalid:443#剩余流量：162.4 GB", "trojan://pw@info.example.invalid:443#套餐到期：2026-12-31"], at: 0)
        demo.append(demo[2].replacingOccurrences(of: "#", with: "#备用 "))
        store.prepareImport(text: Data(demo.joined(separator: "\n").utf8).base64EncodedString(), title: "TAG_Demo_1018.yaml",
                            source: .subscription(host: "sub.example.invalid"),
                            usage: SubscriptionUsage(upload: 3_221_225_472, download: 41_875_931_136, total: 214_748_364_800, expire: Date(timeIntervalSince1970: 1_798_761_600)))
        await shot("19d-import-preview-subscription", size: CGSize(width: 1320, height: 900))
        store.cancelImport()
        await settle(0.4)
        let links = [
            "trojan://pw@jp.example.invalid:443?sni=jp.example.invalid#🇯🇵 东京 Trojan",
            "hysteria2://auth@hk.example.invalid:443?sni=hk.example.invalid#🇭🇰 香港 Hy2",
            "vless://11111111-1111-1111-1111-111111111111@us.example.invalid:443?security=tls&type=ws&path=%2Fws#🇺🇸 美国 VLESS",
            "wireguard://key@wg.example.invalid:51820#WG",
        ].joined(separator: "\n")
        store.importText(Data(links.utf8).base64EncodedString())
        await shot("21-base64-import")
        // The reported clarification loop: four JP nodes, no JP group.
        let jpNodes = (1...4).map { "  - {name: \"[A]JP PrivateNET 0\($0)\", type: ss, server: jp\($0).example.invalid, port: 443, cipher: aes-128-gcm, password: p}" }
        let usNodes = (1...2).map { "  - {name: \"[A]US PrivateNET 0\($0)\", type: ss, server: us\($0).example.invalid, port: 443, cipher: aes-128-gcm, password: p}" }
        store.importText("proxies:\n" + (jpNodes + usNodes).joined(separator: "\n") + "\nrules:\n  - MATCH,DIRECT\n", title: "PrivateNET.yaml")
        store.confirmExits()
        store.send("Netflix 走日本，ChatGPT 走美国")
        await waitIdle(store)
        for _ in 0..<2 {
            guard case .clarify(_, let options) = store.current?.turns.last?.outcome, let prompt = options.first?.prompt else { break }
            store.send(prompt)
            await waitIdle(store)
        }
        await shot("24-clarify-resolved")

        // One service, two regions: a new group named after the service.
        let twhk = (1...2).map { "  - {name: \"🇹🇼 台北 0\($0)\", type: ss, server: tw\($0).example.invalid, port: 443, cipher: aes-128-gcm, password: p}" }
            + (1...2).map { "  - {name: \"🇭🇰 香港 0\($0)\", type: ss, server: hk\($0).example.invalid, port: 443, cipher: aes-128-gcm, password: p}" }
        store.importText("proxies:\n" + twhk.joined(separator: "\n") + "\nproxy-groups:\n  - {name: 🚀 Proxy, type: select, proxies: [\"🇹🇼 台北 01\", \"🇭🇰 香港 01\"]}\nrules:\n  - MATCH,🚀 Proxy\n", title: "TWHK.yaml")
        store.confirmExits()
        store.send("巴哈姆特走台湾和香港")
        await waitIdle(store)
        await shot("25-new-group")
        if let turn = store.current?.turns.last, let item = turn.proposal?.items.first(where: { $0.kind == .group }) {
            store.editingGroup = GroupEditTarget(turnID: turn.id, itemID: item.id)
            await shot("26-group-editor")
            store.editingGroup = nil
            await settle(0.4)
        }

        // "All foreign AI services, excluding Hong Kong and Macau" (reported misunderstanding).
        let regional = """
        proxies:
          - {name: "🇭🇰 香港 01", type: ss, server: hk.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "🇲🇴 澳门 01", type: ss, server: mo.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "🇯🇵 东京 01", type: ss, server: jp.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "🇺🇸 洛杉矶 01", type: ss, server: us.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: 🚀 Proxy, type: select, proxies: [香港自动, 澳门节点, 日本节点, 美国自动]}
          - {name: 香港自动, type: url-test, url: 'https://www.gstatic.com/generate_204', interval: 300, proxies: ["🇭🇰 香港 01"]}
          - {name: 澳门节点, type: select, proxies: ["🇲🇴 澳门 01"]}
          - {name: 日本节点, type: select, proxies: ["🇯🇵 东京 01"]}
          - {name: 美国自动, type: url-test, url: 'https://www.gstatic.com/generate_204', interval: 300, proxies: ["🇺🇸 洛杉矶 01"]}
        rules:
          - MATCH,🚀 Proxy
        """
        store.importText(regional, title: "AI-exclude.yaml")
        store.confirmExits()
        store.send("所有国外AI服务，策略组排除所有港澳节点")
        await waitIdle(store)
        await shot("27-exclude-regions")

        // Model and thinking strength; settings list the service's models.
        store.settings = AISettings(provider: .deepSeek, model: "deepseek-v4-pro", thinkingLevel: .high)
        store.settings.fetchedModels = ["deepseek-flash", "deepseek-v4-pro"]
        store.sessionKey = "sk-snapshot"
        store.useAI = true
        await shot("28-model-choice")
        NSApp.activate()
        store.showingModelPopover = true
        await settle(1.8)
        if let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            capture(popover, to: directory.appendingPathComponent("28-model-popover-\(suffix).png"), composite: true)
        }
        store.showingModelPopover = false
        await settle(0.4)
        // The Settings scene cannot be opened from here; host the same view in a window of its own.
        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(store).tint(.veerAccent)))
        settings.title = "AI"
        settings.setContentSize(CGSize(width: 560, height: 820))
        settings.makeKeyAndOrderFront(nil)
        await settle(1.0)
        capture(settings, to: directory.appendingPathComponent("28-settings-\(suffix).png"))
        store.sessionKey = nil
        await settle(0.6)
        capture(settings, to: directory.appendingPathComponent("28-settings-key-entry-\(suffix).png"))
        store.sessionKey = "sk-snapshot"
        settings.orderOut(nil)
        await settle(0.4)
        store.useAI = false
        store.sessionKey = nil
        store.selectProvider(.deepSeek)

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
    /// `composite` captures the window together with what is behind it: translucent glass windows
    /// (popovers) captured alone are composited over nothing and look gray in light mode.
    static func capture(_ window: NSWindow, to url: URL, composite: Bool = false) {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // optionOnScreenBelowWindow = 1 << 2, optionIncludingWindow = 1 << 3;
            // boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
            var rect = CGRect.null
            if composite, let screen = NSScreen.screens.first {
                let frame = window.frame
                rect = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            }
            let list: UInt32 = composite ? (1 << 2) | (1 << 3) : 1 << 3
            if let image = function(rect, list, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
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
