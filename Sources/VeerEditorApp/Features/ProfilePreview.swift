import Charts
import SwiftUI
import VeerCore

/// Parsed-profile panel shown before an import is added.
struct ProfilePreviewView: View {
    @Environment(EditorStore.self) private var store
    let pending: EditorStore.PendingImport

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                    if let note = pending.result.note {
                        StatusBadge(kind: .info, text: note, compact: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.md)
                            .background(Color.statusInfo.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                    }
                    if let analysis = pending.analysis, !analysis.isEmpty {
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
                    } else {
                        StateView(symbol: "doc.text", title: "配置是空的", message: "没有节点、策略组或规则。仍然可以导入后用对话添加。")
                    }
                }
                .padding(Spacing.xl)
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 760)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(pending.title).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text("\(pending.source.label) · \(pending.result.format.label)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text("解析于 \(pending.parsedAt.formatted(date: .numeric, time: .standard))").font(.caption).foregroundStyle(.secondary)
                if let usage = pending.usage { UsageText(usage: usage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Label("文件解析完成", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
            Spacer()
            if pending.link != nil {
                Button("刷新") { store.refreshPendingImport() }.help("重新下载订阅并解析")
            }
            Button("取消") { store.cancelImport() }.keyboardShortcut(.cancelAction)
            Button("导入并开始编辑") { store.confirmPendingImport() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
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
                    Text(value).font(.title2.weight(.semibold)).foregroundStyle(Color.veerAccent).lineLimit(1).minimumScaleFactor(0.7)
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
                StackedBar(title: "策略组类型", segments: Segment.make(analysis.groupTypes))
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
            Picker("视图", selection: $tab) {
                Text("分组结构").tag(0)
                Text("规则流向").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if tab == 0 { structure } else { flows }
        }
    }

    private var structure: some View {
        let types = analysis.groupTypes.map(\.label)
        return LazyVStack(alignment: .leading, spacing: Spacing.lg) {
            if analysis.groups.isEmpty { Text("没有策略组").font(.callout).foregroundStyle(.secondary) }
            ForEach(types, id: \.self) { type in
                Text("\(type) 策略组").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                Text(group.type).font(.caption).foregroundStyle(.secondary)
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
