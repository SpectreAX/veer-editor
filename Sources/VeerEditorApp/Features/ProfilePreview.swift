import Charts
import SwiftUI
import VeerCore

/// Scrollable parse summary shared by the import preview and the session overview.
struct ProfileSummaryView: View {
    let title: String
    let subtitle: String
    let timestamp: String
    let usage: SubscriptionUsage?
    let note: String?
    let analysis: ProfileAnalysis?
    /// Node clean-up switches, shown only while previewing a generated config.
    var cleanup: ImportCleanupControls?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(title).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        Text(timestamp).font(.caption).foregroundStyle(.secondary)
                        if let usage { UsageText(usage: usage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let note {
                    StatusBadge(kind: .info, text: note, compact: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(Color.statusInfo.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                }
                if let cleanup { cleanup }
                if let analysis, !analysis.isEmpty {
                    StatTiles(analysis: analysis)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Spacing.md) {
                            ProtocolCard(analysis: analysis).frame(maxWidth: .infinity)
                            RuleTargetCard(analysis: analysis).frame(maxWidth: .infinity)
                        }
                        .frame(minWidth: 680)
                        VStack(spacing: Spacing.md) {
                            ProtocolCard(analysis: analysis)
                            RuleTargetCard(analysis: analysis)
                        }
                    }
                    CompositionCard(analysis: analysis)
                    GroupPreviewCard(analysis: analysis)
                } else if analysis == nil {
                    ProgressView("正在解析…").frame(maxWidth: .infinity).padding(Spacing.xxl)
                } else {
                    StateView(symbol: "doc.text", title: "配置是空的", message: "没有节点、策略组或规则。")
                }
            }
            .padding(Spacing.xl)
        }
    }
}

/// Parsed-profile panel shown before an import is added.
struct ProfilePreviewView: View {
    @Environment(EditorStore.self) private var store
    let pending: EditorStore.PendingImport

    /// "Sub-Store · mihomo · 127.0.0.1" for a Sub-Store download, otherwise source and format.
    private var subtitle: String {
        if let link = pending.link, let download = SubscriptionFetcher.subStoreDownload(link) {
            return ["Sub-Store", download.target, link.host].compactMap { $0 }.joined(separator: " · ")
        }
        return "\(pending.source.label) · \(pending.result.format.label)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileSummaryView(title: pending.title, subtitle: subtitle,
                               timestamp: "解析于 \(pending.parsedAt.formatted(date: .numeric, time: .standard))",
                               usage: pending.usage, note: pending.result.note, analysis: pending.analysis,
                               cleanup: pending.result.format == .mihomoYAML ? nil : ImportCleanupControls(options: pending.options))
            Divider()
            HStack(spacing: Spacing.md) {
                Label("文件解析完成", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                Spacer()
                if pending.link != nil {
                    Button("刷新") { store.refreshPendingImport() }.help("重新下载订阅并解析")
                }
                Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("导入并开始编辑") { store.confirmPendingImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .frame(width: 820, height: 760)
    }
}

/// Switches for the clean-up Veer applies to configs it generates from subscriptions.
struct ImportCleanupControls: View {
    @Environment(EditorStore.self) private var store
    let options: ImportOptions

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Text("节点清理").font(.callout.weight(.medium))
            toggle("移除信息节点", \.removeInfoNodes, help: "去掉名称是剩余流量、到期时间或官网等提示的假节点；用量已从订阅响应头读取")
            toggle("移除重复节点", \.removeDuplicates, help: "设置与前面某个节点完全相同（仅名称不同）的节点只保留第一个")
            toggle("添加地区旗帜", \.addRegionFlags, help: "在能识别地区、但还没有旗帜的节点名称前加上国旗")
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<ImportOptions, Bool>, help: String) -> some View {
        Toggle(title, isOn: Binding(get: { options[keyPath: key] }, set: { value in
            var changed = options
            changed[keyPath: key] = value
            store.setPendingImportOptions(changed)
        }))
        .help(help)
    }
}

/// The same parse summary for a session that was already imported: current draft or original.
struct SessionOverviewSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showOriginal = false
    @State private var analysis: ProfileAnalysis?
    @State private var analyzedText: String?

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.current {
                let text = showOriginal ? session.originalText : session.draftText
                ProfileSummaryView(title: session.title, subtitle: session.source.label,
                                   timestamp: "导入于 \(session.createdAt.formatted(date: .numeric, time: .shortened))",
                                   usage: session.subscriptionUsage, note: showOriginal ? session.importNote : nil,
                                   analysis: analyzedText == text ? analysis : nil)
                    .task(id: text.hashValue ^ (showOriginal ? 1 : 0)) {
                        let snapshot = text
                        let result = await Task.detached(priority: .userInitiated) { ProfileAnalysis.analyze(snapshot) }.value
                        analysis = result
                        analyzedText = snapshot
                    }
            }
            Divider()
            HStack(spacing: Spacing.md) {
                SegmentedControl(label: "范围", selection: $showOriginal,
                                 options: [.init(value: false, title: "当前草稿"), .init(value: true, title: "导入时")])
                .fixedSize()
                if store.current?.hasUnexportedChanges == true && !showOriginal {
                    Text("包含未导出的修改").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
            }
            .controlSize(.large)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
        }
        .frame(width: 820, height: 760)
    }
}

struct UsageText: View {
    let usage: SubscriptionUsage

    var body: some View {
        let bytes = ByteCountFormatter()
        var parts: [String] = []
        if let used = usage.used {
            parts.append(usage.total.map { "已用 \(bytes.string(fromByteCount: used)) / \(bytes.string(fromByteCount: $0))" } ?? "已用 \(bytes.string(fromByteCount: used))")
        } else if let total = usage.total {
            parts.append("总流量 \(bytes.string(fromByteCount: total))")
        }
        if let expire = usage.expire { parts.append("\(expire.formatted(date: .numeric, time: .omitted)) 到期") }
        return Text(parts.joined(separator: " · "))
    }
}

// MARK: Cards

struct PreviewCard<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct StatTiles: View {
    let analysis: ProfileAnalysis

    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(analysis.sizeBytes), countStyle: .file)
        let tiles: [(String, String)] = [
            ("\(analysis.proxyCount)", "节点"), ("\(analysis.proxyProviderCount)", "代理集"), ("\(analysis.groupCount)", "策略组"),
            ("\(analysis.ruleCount)", "规则"), ("\(analysis.ruleProviderCount)", "规则集"), (size, "大小"),
        ]
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Spacing.md)], spacing: Spacing.md) {
            ForEach(tiles, id: \.1) { value, label in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(value).font(.title2.weight(.semibold)).foregroundStyle(value == "0" ? Color.secondary : Color.primary)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(padding: Spacing.md)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A slice of a part-to-whole chart: up to six categories plus a neutral "其他".
struct Segment: Identifiable, Hashable {
    let label: String
    let count: Int
    let color: Color
    var id: String { label }

    static func make(_ counts: [ProfileAnalysis.Count], limit: Int = ChartPalette.maxSlots - 1) -> [Segment] {
        let folded = counts.top(limit)
        var segments = folded.top.enumerated().map { Segment(label: $0.element.label, count: $0.element.count, color: ChartPalette.color($0.offset)) }
        if folded.otherCount > 0 { segments.append(Segment(label: "其他（\(folded.otherLabels)）", count: folded.otherCount, color: ChartPalette.other)) }
        return segments
    }
}

/// Legend that doubles as the table view: label, exact count and share for every segment.
struct SegmentLegend: View {
    let segments: [Segment]

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: Spacing.xs + Spacing.xxs) {
            ForEach(segments) { segment in
                HStack(spacing: Spacing.sm) {
                    RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 10, height: 10)
                    Text(segment.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Spacing.sm)
                    Text("\(segment.count)").monospacedDigit().fontWeight(.medium)
                    Text(percentLabel(segment.count, of: total)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct ProtocolCard: View {
    let analysis: ProfileAnalysis
    @State private var selectedAngle: Int?

    var body: some View {
        let segments = Segment.make(analysis.protocols)
        PreviewCard(title: "节点协议", trailing: "\(analysis.proxyCount) 个节点") {
            if segments.isEmpty {
                Text("没有内置节点").font(.callout).foregroundStyle(.secondary)
            } else if segments.count == 1 {
                // One protocol is a single number, not a part-to-whole chart.
                SegmentLegend(segments: segments)
            } else {
                HStack(alignment: .center, spacing: Spacing.lg) {
                    Chart(segments) { segment in
                        SectorMark(angle: .value("数量", segment.count), innerRadius: .ratio(0.64), angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(segment.color)
                            .opacity(highlighted(segments) == nil || highlighted(segments) == segment ? 1 : 0.35)
                    }
                    .chartAngleSelection(value: $selectedAngle)
                    .chartBackground { _ in
                        let focus = highlighted(segments)
                        VStack(spacing: 0) {
                            Text("\(focus?.count ?? analysis.proxyCount)").font(.title2.weight(.semibold))
                            Text(focus?.label ?? "节点").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(width: 132, height: 132)
                    .accessibilityLabel("节点协议：" + segments.map { "\($0.label) \($0.count) 个" }.joined(separator: "，"))
                    SegmentLegend(segments: segments)
                }
            }
        }
    }

    /// The slice under the pointer, from the cumulative angle value.
    private func highlighted(_ segments: [Segment]) -> Segment? {
        guard let selectedAngle else { return nil }
        var running = 0
        for segment in segments {
            running += segment.count
            if selectedAngle <= running { return segment }
        }
        return nil
    }
}

struct RuleTargetCard: View {
    let analysis: ProfileAnalysis

    var body: some View {
        let folded = analysis.ruleTargets.top(6)
        let rows = folded.top + (folded.otherCount > 0 ? [ProfileAnalysis.Count(label: "其他（\(folded.otherLabels)）", count: folded.otherCount)] : [])
        PreviewCard(title: "规则去向", trailing: folded.otherLabels > 0 ? "前 \(folded.top.count) 个出口" : nil) {
            if rows.isEmpty {
                Text("没有规则").font(.callout).foregroundStyle(.secondary)
            } else {
                let maxCount = max(1, rows.map(\.count).max() ?? 1)
                Grid(alignment: .leading, horizontalSpacing: Spacing.sm, verticalSpacing: Spacing.sm) {
                    ForEach(rows, id: \.label) { row in
                        GridRow {
                            Text(row.label).font(.callout).lineLimit(1).truncationMode(.middle)
                                .frame(width: 120, alignment: .trailing).help(row.label)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(row.label.hasPrefix("其他（") ? ChartPalette.other : ChartPalette.color(0))
                                    .frame(width: max(4, proxy.size.width * CGFloat(row.count) / CGFloat(maxCount)))
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(height: 12)
                            Text("\(row.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .leading)
                        }
                        .help("\(row.label)：\(row.count) 条规则")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("规则去向：" + rows.map { "\($0.label) \($0.count) 条" }.joined(separator: "，"))
            }
        }
    }
}

/// 100% stacked single bar with 2pt gaps, plus the legend.
struct StackedBar: View {
    let title: String
    let segments: [Segment]

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.subheadline.weight(.semibold))
            if segments.isEmpty {
                Text("无").font(.callout).foregroundStyle(.secondary)
            } else {
                if segments.count > 1 {
                GeometryReader { proxy in
                    let gaps = CGFloat(segments.count - 1) * 2
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(segment.color)
                                .frame(width: max(2, (proxy.size.width - gaps) * CGFloat(segment.count) / CGFloat(total)))
                                .help("\(segment.label)：\(segment.count)（\(percentLabel(segment.count, of: total))）")
                        }
                    }
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                }
                FlowLayout(spacing: Spacing.md) {
                    ForEach(segments) { segment in
                        HStack(spacing: Spacing.xs) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 10, height: 10)
                            Text(segment.label)
                            Text("\(segment.count)").fontWeight(.medium).monospacedDigit()
                            Text(percentLabel(segment.count, of: total)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct CompositionCard: View {
    let analysis: ProfileAnalysis

    var body: some View {
        let sources = [ProfileAnalysis.Count(label: "内置", count: analysis.builtInProxies)].filter { $0.count > 0 }
            + analysis.providers.map { ProfileAnalysis.Count(label: "\($0.name)（\($0.type ?? "?")）", count: 1) }
        PreviewCard(title: "构成") {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                StackedBar(title: "规则类型", segments: Segment.make(analysis.ruleTypes))
                StackedBar(title: "策略组类型", segments: Segment.make(analysis.groupTypes.map {
                    ProfileAnalysis.Count(label: ProfileAnalysis.groupTypeTitle($0.label), count: $0.count)
                }))
                StackedBar(title: "代理来源", segments: Segment.make(sources))
                if !analysis.providers.isEmpty {
                    Text("代理集按个数计，节点数在导入后由内核拉取。").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct GroupPreviewCard: View {
    let analysis: ProfileAnalysis
    @State private var tab = 0
    @State private var expanded: Set<String> = []

    var body: some View {
        PreviewCard(title: "策略组预览") {
            SegmentedControl(label: "视图", selection: $tab,
                             options: [.init(value: 0, title: "分组结构"), .init(value: 1, title: "规则流向")])
            .fixedSize()
            if tab == 0 { structure } else { flows }
        }
    }

    private var structure: some View {
        let types = analysis.groupTypes.map(\.label)
        return LazyVStack(alignment: .leading, spacing: Spacing.lg) {
            if analysis.groups.isEmpty { Text("没有策略组").font(.callout).foregroundStyle(.secondary) }
            ForEach(types, id: \.self) { type in
                Text("\(ProfileAnalysis.groupTypeTitle(type)) 策略组").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(analysis.groups.filter { $0.type == type }) { group in
                    GroupRow(group: group, expanded: expanded.contains(group.name)) {
                        if expanded.contains(group.name) { expanded.remove(group.name) } else { expanded.insert(group.name) }
                    }
                }
            }
        }
    }

    private var flows: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.sm) {
            if analysis.flows.isEmpty { Text("没有规则").font(.callout).foregroundStyle(.secondary) }
            ForEach(analysis.flows) { flow in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text(flow.target).fontWeight(.medium).lineLimit(1).truncationMode(.middle).frame(width: 180, alignment: .leading)
                    Text("\(flow.ruleCount) 条").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    Text(flow.ruleTypes.map { "\($0.label) \($0.count)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                Divider()
            }
        }
    }
}

struct GroupRow: View {
    let group: ProfileAnalysis.Group
    let expanded: Bool
    let toggle: () -> Void
    static let collapsedLimit = 24

    var body: some View {
        let visible = expanded ? group.members : Array(group.members.prefix(Self.collapsedLimit))
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(group.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(ProfileAnalysis.groupTypeName(group.type)).font(.caption).foregroundStyle(.secondary)
                Text("\(group.referenceCount) 个引用").font(.caption).foregroundStyle(.tertiary)
                if group.includesAll { Tag(text: "包含全部节点") }
            }
            FlowLayout(spacing: Spacing.xs + Spacing.xxs) {
                ForEach(visible, id: \.self) { member in MemberChip(member: member) }
                ForEach(group.providers, id: \.self) { provider in
                    MemberChip(member: .init(name: "代理集 \(provider)", kind: .proxy), symbol: "tray.full")
                }
                if group.members.count > Self.collapsedLimit {
                    Button(expanded ? "收起" : "还有 \(group.members.count - Self.collapsedLimit) 个") { toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct MemberChip: View {
    let member: ProfileAnalysis.Member
    var symbol: String?

    var body: some View {
        let missing = member.kind == .missing
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol ?? icon).imageScale(.small).foregroundStyle(missing ? Color.statusFailure : .secondary)
            Text(member.name).lineLimit(1).truncationMode(.middle)
            if missing { Text("不存在").foregroundStyle(Color.statusFailure) }
        }
        .font(.caption)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 1)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(missing ? Color.statusFailure.opacity(0.5) : Color.separatorLine))
        .frame(maxWidth: 220)
        .help(member.name)
    }

    private var icon: String {
        switch member.kind {
        case .group: "square.stack.3d.up"
        case .proxy: "point.3.connected.trianglepath.dotted"
        case .builtin: "arrow.uturn.right"
        case .missing: "exclamationmark.triangle"
        }
    }
}
