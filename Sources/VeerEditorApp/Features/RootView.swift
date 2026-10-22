import SwiftUI
import VeerCore

struct RootView: View {
    @Environment(EditorStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: Metrics.sidebarWidth, max: 320)
        } detail: {
            DetailView()
        }
        .navigationTitle(store.showingStart || store.current == nil ? "Veer AI Editor" : store.current!.title)
        .navigationSubtitle(store.showingStart ? "" : store.subtitle)
        .sheet(isPresented: $store.showingImport, onDismiss: { store.cancelImport() }) { ImportSheet() }
        .sheet(isPresented: $store.showingRuleSetSheet) { AddRuleSetSheet() }
        .sheet(isPresented: $store.showingOverview) { SessionOverviewSheet() }
        .sheet(item: $store.editingGroup) { GroupEditorSheet(target: $0) }
        .sheet(isPresented: $store.showingExportSheet) { ExportSheet() }
        .sheet(item: Binding(get: { store.payloadTurn }, set: { _ in store.payloadTurnID = nil })) { turn in
            PayloadSheet(turn: turn)
        }
        .alert("删除会话？", isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } })) {
            Button("删除", role: .destructive) { if let session = store.pendingDeletion { store.delete(session) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(store.pendingDeletion?.hasUnexportedChanges == true ? "这个会话有尚未导出的修改，删除后无法恢复。" : "会话的对话与草稿会从本机删除，原始配置文件不受影响。")
        }
    }
}

extension EditorStore {
    var payloadTurn: Turn? { current?.turns.first { $0.id == payloadTurnID } }
}

struct DetailView: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        Group {
            if store.showingStart || store.current == nil {
                StartView()
            } else {
                // One layout for every session: switching between one that is confirming exits and
                // one being edited swaps the content only, instead of rebuilding the inspector's
                // split view (and the views it hosts) on every switch.
                let editing = store.current?.exitsConfirmed == true
                GeometryReader { proxy in
                    Group {
                        if editing { ConversationView() } else { ExitReviewView() }
                    }
                    .inspector(isPresented: Binding(get: { editing && store.inspectorPresented },
                                                    set: { if editing { store.inspectorPresented = $0 } })) {
                        InspectorView()
                            .inspectorColumnWidth(min: 300, ideal: proxy.size.width < Metrics.compactBreakpoint ? 320 : Metrics.inspectorWidth, max: 520)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast) { store.undo() }
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: store.toast)
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Present for every session, disabled while exits are being confirmed: adding and removing
        // toolbar items on each switch rebuilds the window toolbar.
        if !store.showingStart, let current = store.current {
            let editing = current.exitsConfirmed
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.undo() } label: { Label("撤销写入", systemImage: "arrow.uturn.backward") }
                    .help("撤销上一次写入（⌘Z）").disabled(!store.canUndo)
                Button { store.redo() } label: { Label("重做写入", systemImage: "arrow.uturn.forward") }
                    .help("重做（⇧⌘Z）").disabled(!store.canRedo)
                Button { store.showingOverview = true } label: { Label("配置概览", systemImage: "list.bullet.rectangle") }
                    .help("查看配置解析结果（⇧⌘I）")
                Button { openWindow(id: "lookup") } label: { Label("查询工具", systemImage: "magnifyingglass.circle") }
                    .help("规则集、DNS 与 IP 查询（⇧⌘L）")
                Button { store.requestExport() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .help(editing ? "导出完整配置副本（⌘E）" : "确认出口后可以导出")
                    .disabled(!editing)
                Button { store.inspectorPresented.toggle() } label: { Label("检查器", systemImage: "sidebar.right") }
                    .help(editing ? "显示或隐藏检查器（⌥⌘I）" : "确认出口后可以使用检查器")
                    .disabled(!editing)
            }
        }
    }
}
