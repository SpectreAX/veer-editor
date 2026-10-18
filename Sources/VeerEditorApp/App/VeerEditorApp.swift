import AppKit
import SwiftUI
import VeerCore

@main
struct VeerEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = EditorStore.makeForLaunch()

    var body: some Scene {
        Window("Veer AI Editor", id: "main") {
            RootView()
                .environment(store)
                .tint(.veerAccent)
                .frame(minWidth: Metrics.minWindow.width, minHeight: Metrics.minWindow.height)
                .onAppear {
                    delegate.store = store
                    SnapshotRunner.startIfRequested(store: store)
                }
        }
        .defaultSize(width: Metrics.defaultWindow.width, height: Metrics.defaultWindow.height)
        .windowToolbarStyle(.unified)
        .commands { EditorCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
                .tint(.veerAccent)
        }
    }
}

extension EditorStore {
    /// Snapshot runs use isolated state (sessions, keys and preferences) so they never touch the
    /// user's real data or settings.
    static func makeForLaunch() -> EditorStore {
        if ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] != nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-snapshot-\(UUID().uuidString)")
            return EditorStore(store: SessionStore(directory: directory), keyStore: MemoryKeyStore(), defaults: MemoryDefaults(), persist: false)
        }
        return EditorStore()
    }
}

/// Preferences kept in memory only, for snapshot runs and tests: nothing reaches the user's
/// real preferences or leaves files behind.
nonisolated final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    init() { super.init(suiteName: nil)! }

    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { lock.withLock { values[defaultName] = nil } }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
}

final class MemoryKeyStore: KeyStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    func read(for provider: String) -> String? { lock.withLock { values[provider] } }
    func save(_ key: String, for provider: String) throws { lock.withLock { values[provider] = key } }
    func delete(for provider: String) { lock.withLock { values[provider] = nil } }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnexportedSessions, ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] == nil else {
            store?.flush()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "有尚未导出的修改"
        alert.informativeText = "草稿和对话会保存在本机，下次打开可以继续。确定退出吗？"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        store.flush()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct EditorCommands: Commands {
    let store: EditorStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建导入") { store.newImport() }.keyboardShortcut("n")
            Button("导入配置…") { store.openImport() }.keyboardShortcut("o")
            Button("用剪贴板内容导入…") { store.openImport(prefill: NSPasteboard.general.string(forType: .string)) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("导出配置副本…") { store.requestExport() }.keyboardShortcut("e").disabled(store.current == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销写入") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
            Button("重做写入") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
        }
        CommandMenu("编辑草稿") {
            Button("添加在线规则集…") { store.showingRuleSetSheet = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.current?.exitsConfirmed != true || store.isRunning)
            Button("配置概览…") { store.showingOverview = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(store.current == nil)
            Divider()
            Button("写入草稿") { store.write() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("停止生成") { store.cancel() }.keyboardShortcut(".").disabled(!store.isRunning)
        }
        CommandGroup(after: .sidebar) {
            Button(store.inspectorPresented ? "隐藏检查器" : "显示检查器") { store.inspectorPresented.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            ForEach(Array(InspectorTab.allCases.enumerated()), id: \.element) { index, tab in
                Button("检查器：\(tab.title)") {
                    store.inspectorPresented = true
                    store.inspectorTab = tab
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}
