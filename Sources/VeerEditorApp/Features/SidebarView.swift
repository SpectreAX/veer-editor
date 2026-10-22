import AppKit
import SwiftUI
import VeerCore

struct SidebarView: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var filtered: [Session] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(selection: Binding(get: { store.showingStart ? nil : store.selectedID }, set: { if let id = $0 { store.select(id) } })) {
            Section("会话") {
                if store.sessions.isEmpty {
                    Text("还没有会话").font(.callout).foregroundStyle(.secondary)
                } else if filtered.isEmpty {
                    Text("没有匹配“\(search)”的会话").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(filtered) { session in
                    row(session).tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// Search and the new-import action share one row above the list.
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            SidebarSearchField(text: $search, prompt: "搜索会话")
            Button { store.newImport() } label: {
                Image(systemName: "plus").fontWeight(.semibold).foregroundStyle(Color.veerAccent)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(.veerAccent)
            .help("新建导入（⌘N）")
            .accessibilityLabel("新建导入")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private func row(_ session: Session) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Circle().fill(session.hasUnexportedChanges ? Color.veerAccent : .clear)
                .frame(width: Spacing.sm - Spacing.xxs, height: Spacing.sm - Spacing.xxs)
                .accessibilityLabel(session.hasUnexportedChanges ? "有未导出修改" : "")
                .help(session.hasUnexportedChanges ? "有未导出修改" : "")
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if renaming == session.id {
                    TextField("会话名称", text: $renameText)
                        .onSubmit { store.rename(session.id, to: renameText); renaming = nil }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(session.title).lineLimit(1).truncationMode(.middle)
                }
                Text("\(session.source.label) · \(session.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let usage = session.subscriptionUsage {
                    UsageText(usage: usage).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .contextMenu {
            Button("查看解析结果") { store.select(session.id); store.showingOverview = true }
            Button("重命名") { renameText = session.title; renaming = session.id }
            Button("删除…", role: .destructive) { store.pendingDeletion = session }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Divider()
            Button { openSettings() } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")
            Label("配置在本机解析 · AI 只收到匿名结构", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }
}

/// The system search field (magnifier, clear button, Esc to clear) without `.searchable`, so other
/// controls can sit on the same row.
private struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The clear button sends the action, not a text-change notification.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searched(_:))
        field.setAccessibilityLabel(prompt)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func searched(_ field: NSSearchField) { text.wrappedValue = field.stringValue }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
