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

    private var detected: String? {
        let input = store.importInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        return SubscriptionFetcher.looksLikeLink(input) ? "识别为订阅链接，将下载并解析" : "识别为配置内容，将在本机解析"
    }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("导入配置").font(.title3.weight(.semibold))
                Text("选择文件、粘贴订阅链接，或直接粘贴配置内容。Mihomo / Clash YAML、Base64 订阅和分享链接都会自动识别。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.importInput)
                    .font(Typography.code)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(Spacing.sm)
                if store.importInput.isEmpty {
                    Text("https://…  或粘贴配置内容")
                        .font(Typography.code).foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.sm + Spacing.xs).padding(.vertical, Spacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 180)
            .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium)
                .strokeBorder(dropTargeted ? Color.veerAccent : Color.separatorLine, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [6, 4] : [])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                let target: EditorStore = store
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in target.prepareImport(file: url) }
                }
                return true
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: detected == nil ? "doc.on.clipboard" : "checkmark.circle").foregroundStyle(detected == nil ? Color.secondary : Color.veerAccent)
                Text(detected ?? "也可以把文件拖到上面的输入框").foregroundStyle(.secondary)
            }
            .font(.caption)
            HStack {
                Button { store.chooseImportFile() } label: { Label("选择文件…", systemImage: "folder") }
                Spacer()
                Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction)
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
            Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction)
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
                Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("返回修改") { store.importStage = .input }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 600)
    }
}
