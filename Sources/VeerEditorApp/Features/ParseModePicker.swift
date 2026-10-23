import SwiftUI
import VeerCore

/// Composer pill for the parse mode, with a menu of the modes (like Claude's mode menu and
/// Codex's approval menu): each mode with what it does, the current one checked, 1 / 2 to pick.
struct ParseModePicker: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    /// Icon only, for narrow composer rows.
    var compact = false

    var body: some View {
        @Bindable var store = store
        let ai = store.useAI
        Button { store.showingModePicker.toggle() } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: ai ? "sparkles" : "text.magnifyingglass")
                if !compact { Text(ai ? "AI 解析" : "本地解析") }
                if ai && !store.aiConfigured {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusWarning).imageScale(.small)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm + Spacing.xxs)
            .padding(.vertical, Spacing.xs)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(ai ? (store.aiConfigured ? "AI 解析。点按切换解析方式" : "AI 解析：还没有 API Key，会改用本地解析") : "本地解析。点按切换解析方式")
        .accessibilityLabel("解析方式：\(ai ? "AI 解析" : "本地解析")")
        .popover(isPresented: $store.showingModePicker, arrowEdge: .top) {
            ParseModeMenu {
                store.showingModePicker = false
                openSettings()
            }
            .environment(store)
        }
    }
}

private struct ParseModeMenu: View {
    @Environment(EditorStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("解析方式").font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
            ChoiceRow(number: 1, symbol: "sparkles", title: "AI 解析",
                    detail: "由 \(store.settings.provider.title) 的模型理解指令，支持复杂说法、追问和联网搜索；只发送匿名结构。",
                    selected: store.useAI) { choose(ai: true) }
            if store.useAI && !store.aiConfigured {
                HStack(spacing: Spacing.sm) {
                    StatusBadge(kind: .warning, text: "还没有 \(store.settings.provider.title) 的 API Key，暂时会改用本地解析", compact: true)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("设置…", action: openSettings).buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xs)
            }
            ChoiceRow(number: 2, symbol: "text.magnifyingglass", title: "本地解析",
                    detail: "在本机识别常见服务、域名、IP 和地区，不发送任何内容。",
                    selected: !store.useAI) { choose(ai: false) }
        }
        .padding(Spacing.sm)
        .frame(width: 340)
    }

    private func choose(ai: Bool) {
        store.useAI = ai
        store.showingModePicker = false
    }
}
