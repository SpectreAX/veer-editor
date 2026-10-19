import SwiftUI
import VeerCore

/// Shown once after import: which exits Veer found and which regions it inferred.
struct ExitReviewView: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if let draft = store.draft {
                    header(draft)
                    if let note = store.current?.importNote {
                        StatusBadge(kind: .info, text: note)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.md)
                            .background(Color.statusInfo.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Color.statusInfo.opacity(0.25)))
                    }
                    if !draft.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            ForEach(draft.warnings, id: \.self) { warning in
                                StatusBadge(kind: .warning, text: warning).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(Color.statusWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Color.statusWarning.opacity(0.3)))
                    }
                    ExitList(targets: draft.targets)
                    HStack(spacing: Spacing.md) {
                        Button("开始编辑") { store.confirmExits() }
                            .primaryAction()
                            .keyboardShortcut(.defaultAction)
                        Button("稍后") { store.confirmExits() }.neutralControl()
                            .buttonStyle(.bordered).controlSize(.large)
                        Spacer()
                        Text("之后可以在检查器的“出口”里修改").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    StateView(symbol: "exclamationmark.triangle", title: "无法读取这个会话的配置", message: "草稿可能已损坏。可以删除会话后重新导入。")
                }
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: Metrics.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surface)
    }

    private func header(_ draft: ConfigDocument) -> some View {
        let exits = draft.targets.filter { $0.kind != .builtin }
        let unknown = exits.filter { (store.regions[$0.name] ?? .unknown) == .unknown }.count
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("确认出口").font(.title2.weight(.semibold))
            Text("识别到 \(draft.targets.count) 个出口" + (unknown > 0 ? " · \(unknown) 个未指定地区" : ""))
                .font(.headline).foregroundStyle(.secondary)
            Text("使用 AI 时，名称会换成“策略组N（地区）”“节点N（地区）”这样的标签。地区根据名称推断或由你指定，未实测；未指定地区的出口不会被“走日本”这类说法选中，只能用名称或 @ 选择。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(["\(draft.counts.nodes) 个节点", "\(draft.counts.groups) 个策略组", "\(draft.counts.rules) 条规则",
                  draft.counts.providers > 0 ? "\(draft.counts.providers) 个规则集" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Exit rows with an editable region. Shared by the review screen and the inspector.
struct ExitList: View {
    @Environment(EditorStore.self) private var store
    let targets: [Target]

    var body: some View {
        let regions = store.regions
        LazyVStack(spacing: 0) {
            ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                if index > 0 { Divider().padding(.leading, Spacing.lg) }
                HStack(spacing: Spacing.md) {
                    Text(target.name).lineLimit(1).truncationMode(.middle).help(target.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Tag(text: target.kind.label)
                    if target.kind == .builtin {
                        Text(target.name == "DIRECT" ? "直连" : "拦截").font(.callout).foregroundStyle(.secondary)
                            .frame(width: 112, alignment: .trailing)
                    } else {
                        Picker("地区", selection: Binding(
                            get: { regions[target.name] ?? .unknown },
                            set: { store.setRegion($0, for: target.name) }
                        )) {
                            ForEach(Region.allCases, id: \.self) { region in
                                Text(region.displayName).tag(region)
                            }
                        }
                        .labelsHidden()
                        .neutralControl()
                        .frame(width: 112)
                        .accessibilityLabel("\(target.name) 的地区")
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
            }
        }
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.6)))
    }
}
