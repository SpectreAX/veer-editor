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
    /// Snapshot runs use an isolated, in-memory state so they never touch real sessions.
    static func makeForLaunch() -> EditorStore {
        if ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] != nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-snapshot-\(UUID().uuidString)")
            return EditorStore(store: SessionStore(directory: directory), keyStore: MemoryKeyStore(), persist: false)
        }
        return EditorStore()
    }
}

final class MemoryKeyStore: KeyStoring, @unchecked Sendable {
    private var value: String?
    func read() -> String? { value }
    func save(_ key: String) throws { value = key }
    func delete() { value = nil }
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
