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
            Section {
                Button { store.newImport() } label: {
                    Label("新建导入", systemImage: "plus").foregroundStyle(Color.veerAccent).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("导入新的配置（⌘N）")
                .tint(.veerAccent)
            }
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
        .searchable(text: $search, placement: .sidebar, prompt: "搜索会话")
        .safeAreaInset(edge: .bottom) { footer }
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
            Label("配置在本机解析 · AI 只收到匿名出口", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }
}
