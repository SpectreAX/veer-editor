import SwiftUI
import UniformTypeIdentifiers
import VeerCore

struct StartView: View {
    @Environment(EditorStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Spacing.xl)
            VStack(spacing: Spacing.xl) {
                VeerMark()
                VStack(spacing: Spacing.sm) {
                    Text("用一句话修改分流规则").font(.title2.weight(.semibold))
                    Text("导入 Mihomo 配置，说出你想要的分流。每一处改动都会先给你看清楚，再由你决定写不写。")
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                VStack(spacing: Spacing.md) {
                    Button { ImportPanel.open(store: store) } label: {
                        Label("导入配置文件", systemImage: "doc.badge.plus").padding(.horizontal, Spacing.sm)
                    }
                    .primaryAction()
                    .keyboardShortcut("o")

                    HStack(spacing: Spacing.sm) {
                        Button("粘贴配置") { store.showingPasteSheet = true }
                        Button("订阅链接") { store.showingSubscriptionSheet = true }
                        Button("试用示例配置") { store.loadSample() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                if let error = store.importError, !store.showingPasteSheet, !store.showingSubscriptionSheet {
                    StatusBadge(kind: .failure, text: error)
                        .frame(maxWidth: 460)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("也可以把配置或订阅文件拖到这里").font(.callout).foregroundStyle(.tertiary)
            }
            .padding(Spacing.xxl)
            Spacer(minLength: Spacing.xl)
            Label("配置在本机解析。AI 只收到匿名出口与你的指令，不会收到节点地址、密码或订阅链接。", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, Spacing.xl)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(Color.veerAccent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.veerAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    .overlay { Label("松开以导入配置", systemImage: "arrow.down.doc").font(.headline).foregroundStyle(Color.veerAccent) }
                    .padding(Spacing.lg)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in store.importFile(url) }
            }
            return true
        }
        .animation(Motion.quick, value: dropTargeted)
    }
}

/// Veer brand mark: a rounded tile with the "V" route glyph.
struct VeerMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.veerAccent)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Veer")
    }
}

struct SubscriptionSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("从订阅链接导入").font(.headline)
            Text("支持返回 Mihomo / Clash YAML、Base64 订阅或分享链接列表的地址，Veer 会自动识别格式。不跟随重定向，最大 2 MB。链接本身不会被保存。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://", text: $link)
                .textFieldStyle(.roundedBorder)
                .disabled(store.importing)
                .onSubmit(start)
            if store.importing {
                HStack(spacing: Spacing.sm) { ProgressView().controlSize(.small); Text("正在下载并解析…").foregroundStyle(.secondary) }
                    .font(.callout)
            } else if let error = store.importError {
                StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { store.importError = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.importError == nil ? "导入" : "重试", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || store.importing)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .onAppear { store.importError = nil }
    }

    private func start() { Task { await store.importSubscription(link) } }
}

struct PasteSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("粘贴配置").font(.headline)
            Text("可以是 Mihomo / Clash YAML、Base64 订阅内容或分享链接（每行一个），Veer 会自动识别。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(Typography.code)
                .scrollContentBackground(.hidden)
                .padding(Spacing.sm)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.separatorLine))
                .frame(minHeight: 260)
            if let error = store.importError {
                StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("内容只在本机解析").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { store.importError = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") { store.importText(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
        .onAppear {
            store.importError = nil
            if let clip = NSPasteboard.general.string(forType: .string), clip.utf8.count < ConfigDocument.maxBytes, (try? ConfigImporter.normalize(clip)) != nil { text = clip }
        }
    }
}
