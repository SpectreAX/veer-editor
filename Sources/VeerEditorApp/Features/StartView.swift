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
                    Button { store.openImport() } label: {
                        Label("导入配置", systemImage: "doc.badge.plus").padding(.horizontal, Spacing.sm)
                    }
                    .primaryAction()
                    .help("文件、订阅链接或粘贴内容（⌘O）")
                    Button("试用示例配置") { store.loadSample() }
                        .buttonStyle(.bordered)
                }
                Text("支持文件、订阅链接和粘贴内容，格式自动识别。也可以把文件拖到这里。").font(.callout).foregroundStyle(.tertiary)
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
            let target: EditorStore = store
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in target.prepareImport(file: url) }
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
