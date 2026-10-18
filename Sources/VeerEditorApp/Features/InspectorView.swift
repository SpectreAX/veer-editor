import SwiftUI
import VeerCore

struct InspectorView: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("检查器", selection: $store.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in Text(tab.title).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            Divider()
            Group {
                switch store.inspectorTab {
                case .changes: ChangesTab()
                case .rules: RulesTab()
                case .test: TestTab()
                case .exits: ExitsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.surface)
    }
}

// MARK: Changes

struct ChangesTab: View {
    @Environment(EditorStore.self) private var store
    @State private var expandedFolds: Set<Int> = []

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Picker("范围", selection: $store.diffScope) {
                    ForEach(DiffScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Picker("显示方式", selection: $store.changesVisual) {
                    Image(systemName: "square.grid.2x2").tag(true).help("可视化")
                    Image(systemName: "chevron.left.forwardslash.chevron.right").tag(false).help("源码")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("显示方式")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)

            if let texts = store.diffTexts, store.changesVisual {
                let structure = store.structure(texts.old, texts.new)
                if structure.isEmpty {
                    StateView(symbol: "checkmark.circle", title: "没有差异", message: store.diffScope == .original ? "草稿与原始配置一致。" : "这一轮没有改变草稿。")
                } else {
                    VisualChangesView(diff: structure, editable: editableGroups)
                }
            } else if let texts = store.diffTexts {
                let lines = store.diff(texts.old, texts.new)
                let stats = LineDiff.stats(lines)
                if stats.added + stats.removed == 0 {
                    StateView(symbol: "checkmark.circle", title: "没有差异", message: store.diffScope == .original ? "草稿与原始配置一致。" : "这一轮没有改变草稿。")
                } else {
                    HStack(spacing: Spacing.md) {
                        Text("+\(stats.added)").foregroundStyle(Color.veerAccent)
                        Text("−\(stats.removed)").foregroundStyle(Color.statusFailure)
                        Text(caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .font(Typography.codeSmall)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("新增 \(stats.added) 行，删除 \(stats.removed) 行")
                    DiffView(blocks: LineDiff.blocks(lines), expanded: $expandedFolds)
                        // Lazy rows keyed by line index would otherwise be reused across different diffs.
                        .id(texts.old.hashValue ^ texts.new.hashValue)
                }
            } else {
                StateView(symbol: "doc.text.magnifyingglass", title: "还没有修改", message: "生成修改后，这里会显示本轮候选与草稿之间的差异。")
            }
        }
        .onChange(of: store.inspectedTurnID) { expandedFolds = [] }
        .onChange(of: store.diffScope) { expandedFolds = [] }
    }

    /// New groups in the inspected, still-pending proposal: these can be edited before writing.
    private var editableGroups: [String: GroupEditTarget] {
        guard store.diffScope == .turn, let session = store.current,
              let turn = session.turns.first(where: { $0.id == (store.inspectedTurnID ?? store.latestProposalTurnID) }),
              let proposal = turn.proposal, proposal.status == .pending, proposal.baseDraft == session.draftText else { return [:] }
        var result: [String: GroupEditTarget] = [:]
        for item in proposal.items { if let group = item.group { result[group.name] = GroupEditTarget(turnID: turn.id, itemID: item.id) } }
        return result
    }

    private var caption: String {
        guard store.diffScope == .turn, let turn = store.current?.turns.first(where: { $0.id == (store.inspectedTurnID ?? store.latestProposalTurnID) }) else {
            return "原始配置 → 当前草稿"
        }
        switch turn.proposal?.status {
        case .written: return "已写入：\(turn.prompt)"
        case .pending: return "候选（未写入）：\(turn.prompt)"
        default: return turn.prompt
        }
    }
}

struct DiffView: View {
    let blocks: [DiffBlock]
    @Binding var expanded: Set<Int>

    var body: some View {
        GeometryReader { proxy in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    switch block {
                    case .lines(let lines):
                        ForEach(lines) { DiffRow(line: $0) }
                    case let .folded(id, count, lines):
                        if expanded.contains(id) {
                            ForEach(lines) { DiffRow(line: $0) }
                        } else {
                            Button { expanded.insert(id) } label: {
                                Text("… \(count) 行未改动")
                                    .font(Typography.codeSmall).foregroundStyle(.secondary)
                                    .padding(.vertical, Spacing.xs)
                                    .padding(.leading, Spacing.xxl + Spacing.xl)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.surfaceSunken.opacity(0.5))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("展开未改动的行")
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
            .textSelection(.enabled)
            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
        }
        .background(Color.codeBackground)
        }
    }
}

struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 28, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 28, alignment: .trailing)
            Text(prefix).fontWeight(.bold).foregroundStyle(prefixColor).frame(width: Spacing.sm)
            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(.primary).fixedSize()
        }
        .font(Typography.codeSmall)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.kind == .added ? "新增" : line.kind == .removed ? "删除" : "未改动")：\(line.text)")
    }

    private var prefix: String { line.kind == .added ? "+" : line.kind == .removed ? "−" : " " }
    private var prefixColor: Color { line.kind == .added ? .veerAccent : line.kind == .removed ? .statusFailure : .clear }
    private var background: Color { line.kind == .added ? .diffAdded : line.kind == .removed ? .diffRemoved : .clear }
}

// MARK: Rules

struct RulesTab: View {
    @Environment(EditorStore.self) private var store
    @State private var filter = ""
    @State private var expandedProviders: Set<String> = []
    @FocusState private var filterFocused: Bool

    var body: some View {
        let rules = store.draft?.rules ?? []
        let added = store.addedRules
        let indexed = Array(rules.enumerated()).filter { filter.isEmpty || $0.element.localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            HStack {
                TextField("筛选规则（⌘F）", text: $filter).textFieldStyle(.roundedBorder).focused($filterFocused)
                Button("") { filterFocused = true }.keyboardShortcut("f").hidden().frame(width: 0)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            HStack {
                Text("\(rules.count) 条规则 · 本次新增 \(added.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.showingRuleSetSheet = true } label: { Label("添加规则集", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(store.isRunning)
                    .help("添加在线规则集（/ruleset）")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.xs)
            if indexed.isEmpty {
                StateView(symbol: "line.3.horizontal.decrease.circle", title: rules.isEmpty ? "草稿没有规则" : "没有匹配的规则",
                          message: rules.isEmpty ? nil : "试试其他关键词。", actionTitle: rules.isEmpty ? nil : "清除筛选") { filter = "" }
            } else {
                List(indexed, id: \.offset) { index, rule in
                    RuleRow(index: index, rule: rule, isNew: added.contains(rule),
                            provider: providerURL(for: rule), expanded: expandedProviders.contains(rule)) {
                        if expandedProviders.contains(rule) { expandedProviders.remove(rule) } else { expandedProviders.insert(rule) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func providerURL(for rule: String) -> String? {
        let parts = rule.split(separator: ",").map(String.init)
        guard parts.first?.uppercased() == "RULE-SET", parts.count > 1 else { return nil }
        return store.draft?.providers.first { $0.key == parts[1] }?.url ?? "（配置中没有名为 \(parts[1]) 的规则集）"
    }
}

struct RuleRow: View {
    let index: Int
    let rule: String
    let isNew: Bool
    let provider: String?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let parts = rule.split(separator: ",", maxSplits: 2).map(String.init)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(index + 1)").font(Typography.codeSmall).foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(parts.count > 1 ? parts[1] : parts.first ?? "").font(Typography.codeSmall).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: Spacing.xs) {
                        Text(parts.first ?? "").font(.caption2).foregroundStyle(.secondary)
                        if parts.count > 2 {
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(parts[2]).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: Spacing.xs)
                if isNew { Tag(text: "新增", tint: .veerAccent) }
                if provider != nil {
                    Button(action: toggle) { Image(systemName: expanded ? "chevron.up" : "chevron.down") }
                        .buttonStyle(.borderless).help("显示规则集地址")
                }
            }
            if expanded, let provider {
                Text(provider).font(Typography.codeSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, Spacing.xxl + Spacing.xs)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(index + 1) 条：\(rule)\(isNew ? "，新增" : "")")
    }
}

// MARK: Test

struct TestTab: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("测试域名").font(.headline)
                    TextField("例如 www.netflix.com", text: $store.testQuery).textFieldStyle(.roundedBorder)
                    Text("按草稿规则顺序查找第一条命中的规则。只在本机计算，不发起网络请求。").font(.caption).foregroundStyle(.secondary)
                }
                if store.testQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyView()
                } else if let domain = RuleMatcher.normalize(store.testQuery) {
                    if let draft = store.draft {
                        MatchResultView(title: "当前草稿", result: RuleMatcher.match(domain: domain, rules: draft.rules))
                    }
                    if let pending = pendingCandidate, let candidate = store.document(for: pending) {
                        MatchResultView(title: "写入候选后", result: RuleMatcher.match(domain: domain, rules: candidate.rules))
                    }
                } else {
                    StatusBadge(kind: .warning, text: "这不是有效的域名。").font(.callout)
                }
            }
            .padding(Spacing.lg)
        }
    }

    private var pendingCandidate: String? {
        guard let turn = store.current?.turns.last(where: { $0.proposal?.status == .pending }), let proposal = turn.proposal,
              proposal.baseDraft == store.current?.draftText else { return nil }
        return proposal.candidate
    }
}

struct MatchResultView: View {
    let title: String
    let result: RuleMatcher.Result

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let index = result.index, let rule = result.rule {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    StatusBadge(kind: .success, text: "第 \(index + 1) 条 → \(result.target ?? "?")")
                    Text(rule).font(Typography.codeSmall).textSelection(.enabled)
                }
            } else {
                StatusBadge(kind: .warning, text: "没有本地可判定的规则命中，也没有 MATCH 兜底。")
            }
            if !result.skipped.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("需要内核数据，已跳过 \(result.skipped.count) 条（可能提前命中）：").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.skipped.prefix(5), id: \.index) { skipped in
                        Text("第 \(skipped.index + 1) 条  \(skipped.rule)").font(Typography.codeSmall).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if result.skipped.count > 5 { Text("…").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Spacing.md)
    }
}

// MARK: Exits

struct ExitsTab: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("地区为根据名称推断或由你声明，未实测。AI 只看到“出口 N（地区）”。").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ExitList(targets: store.draft?.targets ?? [])
            }
            .padding(Spacing.lg)
        }
    }
}
