import SwiftUI
import UniformTypeIdentifiers
import VeerCore

/// The single import entry point: a file, a subscription link or pasted content, detected
/// automatically, then a parsed preview before anything is added.
struct ImportSheet: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        Group {
            switch store.importStage {
            case .input: ImportInputView()
            case .loading(let message): ImportProgressView(message: message)
            case .failed(let message): ImportFailedView(message: message)
            case .preview(let pending): ProfilePreviewView(pending: pending)
            }
        }
        .animation(Motion.standard, value: stageKey)
    }

    private var stageKey: String {
        switch store.importStage {
        case .input: "input"
        case .loading: "loading"
        case .failed: "failed"
        case .preview(let pending): pending.id.uuidString
        }
    }
}

struct ImportInputView: View {
    @Environment(EditorStore.self) private var store
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var detected: (text: String, ok: Bool)? {
        let input = store.importInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let lines = EditorStore.subscriptionLines(input) {
            guard lines.allSatisfy({ (try? SubscriptionFetcher.validate($0)) != nil }) else {
                return ("其中有 HTTP 链接不是本机或局域网地址，其他订阅请使用 HTTPS", false)
            }
            return ("识别为 \(lines.count) 个订阅链接，将分别下载后合并节点", true)
        }
        guard SubscriptionFetcher.looksLikeLink(input) else { return ("识别为配置内容，将在本机解析", true) }
        guard let url = try? SubscriptionFetcher.validate(input) else { return ("HTTP 链接只能指向本机或局域网地址，其他订阅请使用 HTTPS", false) }
        return SubscriptionFetcher.subStoreDownload(url) == nil ? ("识别为订阅链接，将下载并解析", true)
            : ("识别为 Sub-Store 下载链接，将以 mihomo 格式下载并解析", true)
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("导入配置").font(.title3.weight(.semibold))
                Text("选择文件、粘贴订阅链接，或直接粘贴配置内容。Mihomo / Clash YAML、Base64 订阅和分享链接都会自动识别；每行一个订阅链接可以合并多个订阅。订阅链接需为 HTTPS；本机或局域网的 Sub-Store 等服务可用 HTTP。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.importInput)
                    .font(Typography.code)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(Spacing.sm)
                if store.importInput.isEmpty {
                    Text("https://…、http://127.0.0.1:3000/download/…  或粘贴配置内容")
                        .font(Typography.code).foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.sm + Spacing.xs).padding(.vertical, Spacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 180)
            .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium)
                .strokeBorder(dropTargeted ? Color.veerAccent : Color.separatorLine, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [6, 4] : [])))
            .importsDroppedFile(into: store, isTargeted: $dropTargeted)
            HStack(spacing: Spacing.sm) {
                Image(systemName: detected == nil ? "doc.on.clipboard" : detected?.ok == false ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(detected == nil ? Color.secondary : detected?.ok == false ? Color.statusWarning : Color.veerAccent)
                Text(detected?.text ?? "也可以把文件拖到上面的输入框").foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack {
                Button { store.chooseImportFile() } label: { Label("选择文件…", systemImage: "folder") }.neutralControl()
                Spacer()
                Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("解析") { store.submitImportInput() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.importInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Label("配置只在本机解析；订阅链接不会被保存。", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.xl)
        .frame(width: 600)
        .onAppear { focused = true }
    }
}

struct ImportProgressView: View {
    @Environment(EditorStore.self) private var store
    let message: String

    var body: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
            Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction).neutralControl()
        }
        .padding(Spacing.xxl)
        .frame(width: 600, height: 280)
    }
}

struct ImportFailedView: View {
    @Environment(EditorStore.self) private var store
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("无法导入").font(.title3.weight(.semibold))
            StatusBadge(kind: .failure, text: message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Spacer()
                Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("返回修改") { store.importStage = .input }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 600)
    }
}
