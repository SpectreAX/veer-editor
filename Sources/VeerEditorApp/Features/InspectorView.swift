import SwiftUI
import VeerCore

struct InspectorView: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            SegmentedControl(label: "检查器", selection: $store.inspectorTab,
                             options: InspectorTab.allCases.map { .init(value: $0, title: $0.title) })
            .fixedSize()
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
            // One quiet menu instead of two more segmented rows under the tabs.
            HStack(spacing: Spacing.sm) {
                Menu {
                    Picker("比较", selection: $store.diffScope) {
                        ForEach(DiffScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("显示", selection: $store.changesVisual) {
                        Label("可视化", systemImage: "square.grid.2x2").tag(true)
                        Label("源码差异", systemImage: "chevron.left.forwardslash.chevron.right").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(store.diffScope.title) · \(store.changesVisual ? "可视化" : "源码差异")")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .neutralControl()
                .fixedSize()
                .help("选择比较范围与显示方式")
                Spacer(minLength: 0)
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
        let parts = RuleParts.parse(rule)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(index + 1)").font(Typography.codeSmall).foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(parts.map { $0.payload ?? "其他所有流量" } ?? rule).font(Typography.codeSmall).lineLimit(1).truncationMode(.middle)
                        .help(rule)
                    HStack(spacing: Spacing.xs) {
                        Text(parts?.type ?? "无法解析").font(.caption2).foregroundStyle(.secondary)
                        if let parts {
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(parts.target).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            ForEach(parts.flags, id: \.self) { flag in
                                Text(flag).font(.caption2).foregroundStyle(.tertiary)
                                    .padding(.horizontal, Spacing.xs)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                    .help(flag.lowercased() == "no-resolve" ? "no-resolve：域名请求不为这条规则做 DNS 解析" : flag)
                            }
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
    @Environment(\.openWindow) private var openWindow
    @State private var geosite: GeoSiteDatabase?
    @State private var geoip: GeoIPDatabase?
    @State private var resolution: Resolution?

    /// The domain's addresses from 阿里 DoH, fetched only when an IP rule needs them.
    enum Resolution: Equatable {
        case resolving(String)
        case resolved(String, [String])
        case failed(String, String)
    }

    private func context(for domain: String) -> RuleMatcher.Context {
        var addresses: [String] = []
        if case let .resolved(resolved, found) = resolution, resolved == domain { addresses = found }
        return RuleMatcher.Context(geosite: geosite, geoip: geoip, addresses: addresses, providers: store.draft?.providers ?? [])
    }

    var body: some View {
        @Bindable var store = store
        let domain = RuleMatcher.normalize(store.testQuery)
        let current = domain.flatMap { domain in store.draft.map { RuleMatcher.match(domain: domain, rules: $0.rules, context: context(for: domain)) } }
        let candidate = domain.flatMap { domain in
            pendingCandidate.flatMap { store.document(for: $0) }.map { RuleMatcher.match(domain: domain, rules: $0.rules, context: context(for: domain)) }
        }
        let needsAddress = current?.needsAddress == true || candidate?.needsAddress == true
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("测试域名或 IP").font(.headline)
                    TextField("例如 www.netflix.com 或 192.168.1.5", text: $store.testQuery).textFieldStyle(.roundedBorder)
                    Text("按草稿规则顺序查找第一条命中的规则，域名和 IP 都可以。GEOSITE、GEOIP 与 MetaCubeX 规则集用本机地理数据判断；规则需要 IP 时，用阿里 DoH 解析域名（只发送域名）。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if store.testQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyView()
                } else if let domain {
                    if let current { MatchResultView(title: "当前草稿", result: current) }
                    if let candidate { MatchResultView(title: "写入候选后", result: candidate) }
                    resolutionNote(for: domain, needed: needsAddress)
                    geodataNote
                } else {
                    StatusBadge(kind: .warning, text: "这不是有效的域名或 IP 地址。").font(.callout)
                }
                if let domain {
                    Button {
                        store.lookupRequest = LookupRequest(tab: .ruleSets, text: domain)
                        store.lookupTab = .ruleSets
                        openWindow(id: "lookup")
                    } label: {
                        Label("查找包含它的规则集", systemImage: "magnifyingglass.circle")
                    }
                    .buttonStyle(.link).foregroundStyle(Color.veerAccent)
                    .help("在查询工具中查看哪些 MetaCubeX 规则集包含 \(domain)")
                }
            }
            .padding(Spacing.lg)
        }
        .onAppear { store.refreshGeoStatus() }
        .task(id: store.geoStatus) {
            geosite = try? await store.geo.geosite()
            geoip = try? await store.geo.geoip()
        }
        .task(id: needsAddress ? domain : nil) { await resolve(needsAddress ? domain : nil) }
    }

    @ViewBuilder private func resolutionNote(for domain: String, needed: Bool) -> some View {
        switch resolution {
        case .resolving(let name) where name == domain:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("正在用阿里 DoH 解析 \(domain)…").font(.caption).foregroundStyle(.secondary)
            }
        case let .resolved(name, addresses) where name == domain:
            Text("\(domain) 解析为 \(addresses.prefix(3).joined(separator: "、"))（阿里 DoH），IP 规则按第一个地址判断。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case let .failed(name, reason) where name == domain && needed:
            StatusBadge(kind: .warning, text: "无法解析 \(domain)：\(reason)。需要 IP 的规则无法在本机判断。", compact: true)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    /// What downloading the geodata would add, while it is missing.
    @ViewBuilder private var geodataNote: some View {
        if geosite == nil || geoip == nil {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                if case .running(let file) = store.geoDownload {
                    ProgressView().controlSize(.small)
                    Text("正在下载 \(file.rawValue)…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("下载地理数据后，GEOSITE、GEOIP 与 MetaCubeX 规则集也能确定是否命中（约 30 MB，查询在本机进行）。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("下载") { store.downloadGeoData() }.buttonStyle(.link).foregroundStyle(Color.veerAccent).font(.caption)
                }
            }
        }
    }

    private func resolve(_ domain: String?) async {
        guard let domain else { return }
        switch resolution {
        case .resolved(domain, _), .failed(domain, _): return
        default: break
        }
        // Wait for typing to stop before sending anything.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        resolution = .resolving(domain)
        do {
            let result = try await DNSResolver().lookup(domain, type: .a, server: DNSServer.presets[1].server)
            let addresses = result.answers.compactMap(\.address).map(\.description)
            resolution = addresses.isEmpty ? .failed(domain, "\(result.status)，没有 IPv4 地址") : .resolved(domain, addresses)
        } catch {
            guard !Task.isCancelled else { return }
            resolution = .failed(domain, (error as? EditorError)?.message ?? error.localizedDescription)
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
            if let likely = result.likely {
                // A rule set named after the service almost certainly matches before anything local.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    StatusBadge(kind: .warning, text: "很可能命中第 \(likely.index + 1) 条 → \(result.likelyTarget ?? "?")")
                    Text(likely.rule).font(Typography.codeSmall).textSelection(.enabled)
                    Text("规则集的内容要下载后才能确认；如果不在其中，" + (result.index.map { "会命中第 \($0 + 1) 条 → \(result.target ?? "?")。" } ?? "没有其他规则命中。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else if let index = result.index, let rule = result.rule {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    StatusBadge(kind: result.certain ? .success : .info,
                                text: "第 \(index + 1) 条 → \(result.target ?? "?")" + (result.certain ? "" : "（前面有规则需要运行时判断）"))
                    Text(rule).font(Typography.codeSmall).textSelection(.enabled)
                    if result.byGeodata {
                        Text("由本机 MetaCubeX 地理数据确认" + (result.address.map { "（按 \($0) 判断）" } ?? "") + "。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                StatusBadge(kind: .warning, text: "没有本地可判定的规则命中，也没有 MATCH 兜底。")
            }
            if !result.skipped.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("以下 \(result.skipped.count) 条无法在本机判断（非 MetaCubeX 的规则集、没有地理数据，或还没有解析出 IP），已跳过；实际可能更早命中：")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text("地区根据名称推断或由你指定，未实测。使用 AI 时，名称会换成“策略组N（地区）”这样的标签。").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ExitList(targets: store.draft?.targets ?? [])
            }
            .padding(Spacing.lg)
        }
    }
}
