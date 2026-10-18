import AppKit
import SwiftUI
import VeerCore

struct CompletionItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let insertion: String
    var tag: String?
}

/// Bottom composer: auto-growing input, @ exit and / command completion, mode switch, send/stop.
struct ComposerView: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var height: CGFloat = 22
    @State private var query: (trigger: Character, text: String)?
    @State private var highlighted = 0
    @State private var replaceRequest: CompletionItem?

    private var completions: [CompletionItem] {
        guard let query else { return [] }
        let needle = query.text.lowercased()
        if query.trigger == "/" {
            let commands = [
                CompletionItem(id: "/test", title: "/test", detail: "测试域名命中哪条规则", insertion: "/test "),
                CompletionItem(id: "/ruleset", title: "/ruleset", detail: "添加在线规则集", insertion: "/ruleset"),
                CompletionItem(id: "/undo", title: "/undo", detail: "撤销上一次写入", insertion: "/undo"),
                CompletionItem(id: "/redo", title: "/redo", detail: "重做写入", insertion: "/redo"),
                CompletionItem(id: "/export", title: "/export", detail: "导出完整配置副本", insertion: "/export"),
                CompletionItem(id: "/rules", title: "/rules", detail: "查看草稿规则", insertion: "/rules"),
            ]
            return commands.filter { needle.isEmpty || $0.title.contains(needle) }
        }
        let regions = store.regions
        return (store.draft?.targets ?? [])
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            .prefix(8)
            .map { target in
                let region = target.kind == .builtin ? (target.name == "DIRECT" ? "直连" : "拦截") : (regions[target.name] ?? .unknown).displayName
                return CompletionItem(id: target.id, title: target.name, detail: region, insertion: "@\(target.name) ", tag: target.kind.label)
            }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .topLeading) {
                    if store.composerText.isEmpty {
                        Text("描述分流，例如“Netflix 走日本，ChatGPT 走美国”")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, Spacing.xs + 1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $store.composerText, height: $height, query: $query,
                        focusToken: store.composerFocusToken, replaceRequest: $replaceRequest,
                        hasCompletions: !completions.isEmpty,
                        onMove: { delta in
                            guard !completions.isEmpty else { return }
                            highlighted = (highlighted + delta + completions.count) % completions.count
                        },
                        onPick: { pick(completions[min(highlighted, completions.count - 1)]) },
                        onSubmit: { store.send() }
                    )
                    .frame(height: height)
                    .disabled(store.isRunning)
                    .accessibilityLabel("分流指令")
                }
                HStack(spacing: Spacing.sm) {
                    modeMenu
                    Spacer()
                    Text("请勿粘贴密钥或订阅链接").font(.caption).foregroundStyle(.tertiary)
                    if store.isRunning {
                        Button { store.cancel() } label: { Image(systemName: "stop.fill") }
                            .help("停止生成（⌘.）").accessibilityLabel("停止生成")
                            .buttonStyle(.glass).controlSize(.large)
                            .buttonBorderShape(.circle)
                    } else {
                        Button { store.send() } label: { Image(systemName: "arrow.up") .fontWeight(.semibold) }
                            .help("发送（↩）").accessibilityLabel("发送")
                            .buttonStyle(.glassProminent).tint(.veerAccent).controlSize(.large)
                            .buttonBorderShape(.circle)
                            .disabled(store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.large + Spacing.xs, style: .continuous))
            .overlay(alignment: .topLeading) {
                if !completions.isEmpty {
                    CompletionList(items: completions, highlighted: min(highlighted, completions.count - 1), pick: pick)
                        .alignmentGuide(.top) { $0[.bottom] + Spacing.sm }
                }
            }
            Text("↩ 发送 · ⇧↩ 换行 · @ 选择出口 · / 命令")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .onChange(of: query?.text) { highlighted = 0 }
    }

    private var modeMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("解析方式", selection: $store.useAI) {
                Text(store.aiConfigured ? "AI · \(store.settings.provider.title)" : "AI（未配置）").tag(true)
                Text("本地解析").tag(false)
            }
            .pickerStyle(.inline)
            Divider()
            Picker("模型 · \(store.settings.provider.title)", selection: Binding(get: { store.settings.model }, set: { model in
                store.settings.select(model: model)
                store.useAI = true
            })) {
                ForEach(composerModels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .disabled(!store.aiConfigured)
            let style = store.settings.thinkingStyle
            if style.adjustable {
                Divider()
                Picker("深度思考", selection: Binding(get: { store.settings.effectiveLevel }, set: { store.settings.thinkingLevel = $0 })) {
                    ForEach(style.levels) { Text(style.title(of: $0)).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(!store.aiConfigured)
            }
            Divider()
            Button("AI 设置…") { openSettings() }
        } label: {
            Label(store.effectiveUseAI ? "AI · \(store.settings.modelLabel)" : (store.useAI ? "本地解析 · 配置 AI" : "本地解析"),
                  systemImage: store.effectiveUseAI ? (store.settings.thinks ? "brain" : "sparkles") : "text.magnifyingglass")
                .font(.callout)
                .padding(.horizontal, Spacing.sm + Spacing.xxs)
                .padding(.vertical, Spacing.xs)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("选择解析方式与模型")
    }

    /// Suggested models plus the fetched list when it is short enough for a menu.
    private var composerModels: [String] {
        store.settings.models(includingFetched: store.settings.fetchedModels.count <= 16)
    }

    private func pick(_ item: CompletionItem) {
        replaceRequest = item
        query = nil
    }
}

struct CompletionList: View {
    let items: [CompletionItem]
    let highlighted: Int
    let pick: (CompletionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { pick(item) } label: {
                    HStack(spacing: Spacing.sm) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.md)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        if let tag = item.tag { Tag(text: tag) }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs + Spacing.xxs)
                    .background(index == highlighted ? Color.veerAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.xs)
        .frame(width: 340)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.separatorLine))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// NSTextView wrapper: Return sends unless an input method is composing; reports @ and / tokens.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var query: (trigger: Character, text: String)?
    let focusToken: Int
    @Binding var replaceRequest: CompletionItem?
    let hasCompletions: Bool
    let onMove: (Int) -> Void
    let onPick: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = Spacing.xs
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = scroll.documentView as! NSTextView
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.recalculate(textView)
        }
        if let item = replaceRequest {
            DispatchQueue.main.async {
                context.coordinator.insert(item, into: textView)
                replaceRequest = nil
            }
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusToken: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusToken = parent.focusToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculate(textView)
            updateQuery(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateQuery(textView)
        }

        func recalculate(_ textView: NSTextView) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = (textView.font?.boundingRectForFont.height ?? 17).rounded(.up)
            let used = layout.usedRect(for: container).height
            let next = min(max(used, line), line * 8)
            if abs(parent.height - next) > 0.5 { DispatchQueue.main.async { self.parent.height = next } }
            textView.enclosingScrollView?.hasVerticalScroller = used > line * 8
        }

        /// The token right before the caret, if it starts with @ (anywhere) or / (at the start).
        func updateQuery(_ textView: NSTextView) {
            let string = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret <= string.length, !textView.hasMarkedText() else { return }
            let prefix = string.substring(to: caret)
            var found: (Character, String)?
            if let at = prefix.lastIndex(of: "@") {
                let token = String(prefix[prefix.index(after: at)...])
                if !token.contains("\n"), token.count <= 40, !token.contains("，"), !token.contains(",") { found = ("@", token) }
            }
            if found == nil, prefix.hasPrefix("/"), !prefix.contains(" ") { found = ("/", String(prefix.dropFirst())) }
            let current = parent.query
            if current?.trigger != found?.0 || current?.text != found?.1 {
                DispatchQueue.main.async { self.parent.query = found.map { (trigger: $0.0, text: $0.1) } }
            }
        }

        func insert(_ item: CompletionItem, into textView: NSTextView) {
            let string = textView.string as NSString
            let caret = textView.selectedRange().location
            let prefix = string.substring(to: caret)
            let start: Int
            if item.insertion.hasPrefix("/") { start = 0 }
            else if let at = prefix.range(of: "@", options: .backwards) { start = prefix.distance(from: prefix.startIndex, to: at.lowerBound) }
            else { start = caret }
            let nsStart = (prefix as NSString).length - (String(prefix.dropFirst(start)) as NSString).length
            let range = NSRange(location: nsStart, length: caret - nsStart)
            if textView.shouldChangeText(in: range, replacementString: item.insertion) {
                textView.replaceCharacters(in: range, with: item.insertion)
                textView.didChangeText()
            }
            textView.window?.makeFirstResponder(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.hasCompletions { parent.onPick(); return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if parent.hasCompletions { parent.onPick(); return true }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if parent.hasCompletions { parent.onMove(-1); return true }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if parent.hasCompletions { parent.onMove(1); return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.hasCompletions { DispatchQueue.main.async { self.parent.query = nil }; return true }
                return false
            default:
                return false
            }
        }
    }
}
