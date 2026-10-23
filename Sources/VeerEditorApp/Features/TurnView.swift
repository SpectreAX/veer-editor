import SwiftUI
import VeerCore

struct TurnView: View {
    @Environment(EditorStore.self) private var store
    let turn: Turn

    var body: some View {
        if case .note(let text) = turn.outcome {
            HStack(spacing: Spacing.sm) {
                Rectangle().fill(Color.separatorLine).frame(height: 1)
                Label(text, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(Color.separatorLine).frame(height: 1)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                UserBubble(text: turn.prompt)
                AssistantTurn(turn: turn)
            }
        }
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: Spacing.xxxl * 2)
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.md + Spacing.xxs)
                .padding(.vertical, Spacing.sm)
                .background(Color.userBubble, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                .accessibilityLabel("你：\(text)")
        }
    }
}

struct AssistantTurn: View {
    @Environment(EditorStore.self) private var store
    let turn: Turn
    @State private var stepsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            StepsView(turn: turn, expanded: $stepsExpanded)
            if let reasoning = turn.reasoning, !reasoning.isEmpty {
                ReasoningView(text: reasoning, running: turn.outcome == .running, source: turn.mode.label)
            }
            if let understanding = turn.understanding, !understanding.isEmpty {
                Label { Text(understanding).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(Color.veerAccent)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("AI 的理解：\(understanding)")
            }
            if let lookups = turn.lookups {
                LookupHintsView(hints: lookups, local: turn.mode == .local)
            }
            if let searches = turn.searches, !searches.isEmpty {
                SearchRecordsView(records: searches, running: turn.outcome == .running)
            }
            if let checks = turn.checks, !checks.isEmpty {
                CheckRecordsView(records: checks, running: turn.outcome == .running)
            }
            if let problem = turn.repairedFrom {
                Label("第一次回答无法使用（\(problem)），已自动让 AI 修正。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            switch turn.outcome {
            case .running, .note:
                EmptyView()
            case .proposal(let proposal):
                ProposalView(turn: turn, proposal: proposal)
            case .noChange(let text):
                Text(text).foregroundStyle(.secondary)
            case let .clarify(question, options):
                ClarificationView(question: question, options: options, enabled: isLatest, fromPlan: turn.executionMode == .plan)
            case let .clarification(question, suggestions):
                ClarificationView(question: question, options: suggestions.map { ClarifyOption(label: $0) }, enabled: isLatest)
            case .outOfScope(let text):
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    StatusBadge(kind: .info, text: "超出编辑范围", compact: true)
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
            case let .failure(message, opensSettings, canUseLocal):
                FailureView(turn: turn, message: message, opensSettings: opensSettings, canUseLocal: canUseLocal)
            case .cancelled:
                Text("已停止。草稿没有变化。").foregroundStyle(.secondary)
            }
            if turn.sentPayload != nil, turn.outcome != .running, turn.proposal == nil {
                Button("查看发送给 AI 的内容") { store.payloadTurnID = turn.id }
                    .buttonStyle(.link).foregroundStyle(Color.veerAccent).font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Only the latest question can be answered; older ones stay readable.
    private var isLatest: Bool { store.current?.turns.last(where: { !$0.isNote })?.id == turn.id }
}

struct ClarificationView: View {
    @Environment(EditorStore.self) private var store
    let question: String
    let options: [ClarifyOption]
    let enabled: Bool
    /// The options came from a plan-mode answer: choosing one should produce changes.
    var fromPlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(question).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !options.isEmpty {
                FlowLayout(spacing: Spacing.sm) {
                    ForEach(options, id: \.self) { option in
                        // A resolved prompt replaces only the ambiguous phrase; otherwise send a short
                        // follow-up that the AI resolves against the conversation.
                        Chip(text: option.label) {
                            store.send(option.prompt ?? "走 @\(option.label)", executionMode: fromPlan ? .manual : nil)
                        }
                            .disabled(!enabled || store.isRunning)
                            .help(option.prompt ?? "走 @\(option.label)")
                    }
                }
            }
        }
    }
}

struct StepsView: View {
    let turn: Turn
    @Binding var expanded: Bool

    private var running: Bool { turn.outcome == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if running {
                rows
            } else if !turn.steps.isEmpty {
                Button { withAnimation(Motion.standard) { expanded.toggle() } } label: {
                    HStack(spacing: Spacing.xs) {
                        if let icon = summaryIcon { Image(systemName: icon.0).foregroundStyle(icon.1) }
                        Text(summary)
                        Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibleSummary)，\(expanded ? "已展开" : "已折叠")")
                .help("查看 Veer 处理这条指令的步骤")
                if expanded {
                    rows.padding(.leading, Spacing.lg)
                    Text("步骤是 Veer 的真实任务状态，不是模型的推理过程。")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, Spacing.lg)
                }
            }
        }
    }

    /// Only problems get an icon; a finished turn's meta line stays quiet.
    private var summaryIcon: (String, Color)? {
        if turn.steps.contains(where: { $0.state == .failed }) { return ("xmark.circle", .statusFailure) }
        if turn.steps.contains(where: { $0.state == .cancelled }) { return ("minus.circle", .secondary) }
        return nil
    }

    private var summary: String {
        let failed = turn.steps.contains { $0.state == .failed }
        let cancelled = turn.steps.contains { $0.state == .cancelled }
        let time = turn.duration.map { String(format: " · %.1f 秒", $0) } ?? ""
        let head = failed ? "处理失败 · " : cancelled ? "已停止 · " : ""
        return "\(head)\(turn.mode.label)\(time)"
    }

    private var accessibleSummary: String {
        "\(summary)，完成 \(turn.steps.filter { $0.state == .done }.count) 步"
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Spacing.xs + Spacing.xxs) {
            ForEach(turn.steps) { step in
                HStack(spacing: Spacing.sm) {
                    icon(step.state).frame(width: Spacing.lg)
                    Text(step.title).foregroundStyle(step.state == .waiting ? .tertiary : .primary)
                    if let detail = step.detail {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stateLabel(step.state))
            }
        }
    }

    @ViewBuilder private func icon(_ state: Turn.Step.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.veerAccent)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.statusFailure)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func stateLabel(_ state: Turn.Step.State) -> String {
        switch state {
        case .waiting: "等待"
        case .running: "进行中"
        case .done: "完成"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

struct ProposalView: View {
    @Environment(EditorStore.self) private var store
    let turn: Turn
    let proposal: Turn.Proposal

    private var acceptedCount: Int { proposal.accepted.count }
    private var editable: Bool { proposal.status == .pending && proposal.baseDraft == store.current?.draftText }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(summary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Spacing.sm) {
                ForEach(proposal.items) { item in
                    ChangeRow(item: item, accepted: proposal.accepted.contains(item.id), editable: editable,
                              edit: item.kind == .group && editable ? { store.editingGroup = GroupEditTarget(turnID: turn.id, itemID: item.id) } : nil) { accepted in
                        store.setAccepted(accepted, item: item.id, turnID: turn.id)
                    }
                    .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.7)))
                }
            }

            if store.revalidating.contains(turn.id) {
                HStack(spacing: Spacing.sm) { ProgressView().controlSize(.small); Text("正在按你的选择重新生成并校验…").foregroundStyle(.secondary) }
                    .font(.callout)
            } else {
                ValidationView(result: proposal.validation)
            }
            actions
        }
    }

    private var summary: String {
        switch proposal.status {
        case .pending where !editable: "这组修改基于旧草稿生成。"
        case .pending: acceptedCount == proposal.items.count
            ? "准备了 \(proposal.items.count) 项分流修改，等待你确认。"
            : "准备了 \(proposal.items.count) 项分流修改，已选择 \(acceptedCount) 项。"
        case .written: "已把 \(acceptedCount) 项修改写入草稿。"
        case .undone: "这组修改写入后已被撤销。"
        case .discarded: "已放弃这组修改，草稿没有变化。"
        case .stale: "这组修改基于旧草稿生成。"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Spacing.md) {
            switch proposal.status {
            case .pending where editable:
                Button(acceptedCount == proposal.items.count ? "写入草稿" : "写入 \(acceptedCount) 项") { store.write(turnID: turn.id) }
                    .primaryAction()
                    .disabled(!store.canWrite(turn))
                    .help("写入草稿（⇧⌘↩）。原始文件不会改变，导出后才生成新文件。")
                Button("放弃") { store.discard(turnID: turn.id) }.neutralControl()
                    .buttonStyle(.bordered).controlSize(.large)
                if proposal.validation.status == .failed {
                    Text("校验未通过，不能写入").font(.callout).foregroundStyle(Color.statusFailure)
                } else if acceptedCount == 0 {
                    Text("至少选择一项").font(.callout).foregroundStyle(.secondary)
                } else if let mode = turn.executionMode, let reason = mode.heldReason(validation: proposal.validation) {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            case .undone:
                StatusBadge(kind: .neutral, text: "已撤销")
                if store.current?.redoStack.last == proposal.writtenTo { Button("重做") { store.redo() }.buttonStyle(.link).foregroundStyle(Color.veerAccent) }
            case .written:
                StatusBadge(kind: .success, text: turn.autoWritten == true ? "已按\(turn.executionMode?.title ?? "")模式直接写入草稿" : "已写入草稿")
                if store.current?.undoStack.last == proposal.writtenFrom, store.current?.draftText == proposal.writtenTo {
                    Button("撤销") { store.undo() }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
            case .discarded:
                StatusBadge(kind: .neutral, text: "已放弃")
            case .pending, .stale:
                StatusBadge(kind: .warning, text: "已失效 · 草稿已变化，请重新生成")
                Button("重新生成") { store.retry(turnID: turn.id) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
            }
            if !store.inspectorShowsChanges(of: turn.id) {
                Button("查看差异") { store.showDiff(for: turn.id) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                    .help("在右侧检查器中查看这一轮的变更")
            }
            if turn.sentPayload != nil {
                Button("查看发送给 AI 的内容") { store.payloadTurnID = turn.id }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
            }
            Spacer()
        }
        .font(.callout)
    }
}

struct ChangeRow: View {
    @Environment(EditorStore.self) private var store
    let item: ChangeItem
    let accepted: Bool
    let editable: Bool
    var edit: (() -> Void)?
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                title
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if !item.replaced.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Text(item.kind == .removeRule ? "删除" : "替换").font(.caption).foregroundStyle(.secondary)
                        ForEach(item.replaced, id: \.self) { rule in
                            Text(rule).font(Typography.codeSmall).foregroundStyle(Color.statusFailure)
                                .strikethrough(true, color: Color.statusFailure.opacity(0.6))
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                                .background(Color.diffRemoved, in: RoundedRectangle(cornerRadius: Radius.small - 2))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let edit {
                Button(action: edit) { Label("编辑", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderless).font(.callout).help("修改名称、类型和成员")
            }
            Toggle("接受", isOn: Binding(get: { accepted }, set: { toggle($0) }))
                .toggleStyle(.checkbox).labelsHidden().tint(.veerAccent)
                .help(accepted ? "已接受，取消勾选则不写入这一项" : "勾选以接受这一项")
                .disabled(!editable)
                .accessibilityLabel("\(accessibilityText)，\(accepted ? "已接受" : "已拒绝")")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .opacity(accepted || !editable ? 1 : 0.55)
    }

    @ViewBuilder private var title: some View {
        HStack(spacing: Spacing.sm) {
            if item.kind == .group {
                Image(systemName: "square.stack.3d.up.badge.a").foregroundStyle(Color.veerAccent)
                Text("新建策略组").foregroundStyle(.secondary)
            }
            // The name keeps its width; the label and type tag give way first in narrow windows.
            Text(item.subject).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            if item.kind == .group {
                Tag(text: ProfileAnalysis.groupTypeTitle(item.group?.type ?? "select"))
            } else if item.kind == .removeRule {
                Text("删除规则").foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.secondary)
                Text(targetText).lineLimit(1).truncationMode(.middle)
                    .help("括号里是出口所在地区：根据名称推断或由你指定，未实测。可在检查器“出口”中更正。")
            }
        }
    }

    private var targetText: String {
        guard let name = item.targetName else { return "" }
        if name == "DIRECT" { return "直连" }
        if name == "REJECT" { return "拦截" }
        let region = store.regions[name] ?? .unknown
        return region == .unknown ? name : "\(name)（\(region.displayName)）"
    }

    private var detail: String {
        if let group = item.group {
            let byRegion = group.regionCounts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "、")
            let excluded = group.excluded.map { " · 已排除\($0.joined(separator: "、"))，未指定地区的出口未加入" } ?? ""
            return "包含 \(group.members.count) 个出口：\(byRegion)\(excluded) · 追加到 proxy-groups 末尾，不改动已有策略组"
        }
        if let provider = item.provider {
            return "规则集 \(provider.sourceLabel) · \(provider.verification.label)"
        }
        return item.rule ?? "\(item.matchType),\(item.match)"
    }

    private var accessibilityText: String {
        switch item.kind {
        case .group: "新建策略组 \(item.subject)，包含 \(item.group?.members.count ?? 0) 个出口"
        case .removeRule: "删除 \(item.subject) 的规则"
        default: "\(item.subject) 到 \(targetText)"
        }
    }
}

struct ValidationView: View {
    let result: ValidationResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: StatusKind(result.status), text: result.message, compact: true)
                    .padding(.horizontal, Spacing.sm + Spacing.xxs).padding(.vertical, Spacing.xs)
                    .background(StatusKind(result.status).color.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(StatusKind(result.status).color.opacity(0.25)))
                if result.detail != nil {
                    Button(expanded ? "收起" : "详情") { expanded.toggle() }.buttonStyle(.link).foregroundStyle(Color.veerAccent).font(.callout)
                }
            }
            if expanded, let detail = result.detail {
                Text(detail)
                    .font(Typography.codeSmall)
                    .textSelection(.enabled)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
        }
    }
}

struct FailureView: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let turn: Turn
    let message: String
    let opensSettings: Bool
    let canUseLocal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            StatusBadge(kind: .failure, text: message).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Spacing.sm) {
                if opensSettings { Button("打开设置") { openSettings() } }
                if canUseLocal { Button("改用本地解析") { store.retry(turnID: turn.id, useLocal: true) } }
                Button("重试") { store.retry(turnID: turn.id) }
            }
            .buttonStyle(.bordered)
            .disabled(store.isRunning)
        }
    }
}

struct PayloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorStore.self) private var store
    let turn: Turn

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text("发送给 AI 的内容").font(.headline)
                Spacer()
                if turn.sentPayload?.config != nil {
                    SegmentedControl(label: "查看方式", selection: $store.payloadComparing,
                                     options: [.init(value: false, title: "发送的内容"), .init(value: true, title: "与原始配置对照")])
                    .fixedSize()
                }
            }
            if store.payloadComparing, let payload = turn.sentPayload {
                PayloadComparisonView(payload: payload)
            } else {
                sentContent
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("未发送：真实名称、节点地址/端口/密码/协议参数、订阅与规则集地址、DNS/TUN 等配置", systemImage: "lock.shield")
                Label("你在指令里亲自输入的内容会原样发送（出口名除外），请勿填写密钥", systemImage: "exclamationmark.triangle")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl() }
        }
        .padding(Spacing.xl)
        .frame(width: store.payloadComparing ? 920 : 640, height: 680)
    }

    @ViewBuilder private var sentContent: some View {
        Text(turn.sentPayload?.config == nil ? "这是本轮请求中除系统说明外的全部内容。出口名称已替换为匿名标签。"
             : "这是本轮发送的匿名配置、对话与指令。配置已去除真实名称、节点参数和各类地址；系统说明见下方。")
            .font(.callout).foregroundStyle(.secondary)
        ScrollView {
            Text(turn.sentPayload?.readable ?? "本轮没有发送 AI 请求。")
                .font(Typography.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.md)
        }
        .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.separatorLine))
        .frame(minHeight: 220)
        if let searches = turn.searches, !searches.isEmpty {
            DisclosureGroup("联网搜索结果（也已发送给 AI，共 \(searches.count) 条查询）") {
                ScrollView {
                    Text(SearchQueries.message(for: searches, refused: [], lastRound: false)).font(Typography.codeSmall).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                }
                .frame(height: 160)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            .font(.callout)
        }
        if let system = turn.sentPayload?.system {
            DisclosureGroup("系统说明（规则与上面的匿名配置）") {
                ScrollView {
                    Text(system).font(Typography.codeSmall).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                }
                .frame(height: 180)
                .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            .font(.callout)
        }
    }
}

/// The original configuration next to what the AI received, one row per node, group, rule set,
/// rule and replaced value. Built on this Mac from the draft the request was made from.
struct PayloadComparisonView: View {
    @Environment(EditorStore.self) private var store
    let payload: AIRequestPayload
    @State private var result: Result?
    @State private var query = ""

    enum Result { case ready(PayloadComparison, exact: Bool), missing }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("左侧是你的配置（只在本机），右侧是 AI 收到的对应内容。").font(.callout).foregroundStyle(.secondary)
            switch result {
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                StateView(symbol: "doc.questionmark", title: "找不到发送时的配置",
                          message: "这一轮之后草稿被替换或会话被清理，无法重建对照。“发送的内容”仍可查看。")
            case let .ready(comparison, exact):
                if !exact {
                    StatusBadge(kind: .warning, text: "发送后更正过出口地区，对照与实际发送的标签可能略有不同", compact: true)
                }
                TextField("搜索名称、规则或标签", text: $query)
                    .textFieldStyle(.roundedBorder)
                table(comparison)
            }
        }
        .task(id: payload.sourceDigest ?? payload.config) {
            guard let session = store.current else { result = .missing; return }
            let payload = payload
            result = await Task.detached(priority: .userInitiated) { () -> Result in
                let regions: (ConfigDocument) -> [String: Region] = { session.regions(for: $0.targets) }
                guard let source = session.sourceDraft(for: payload, regions: regions),
                      let rebuilt = PayloadComparison.rebuild(for: payload, source: source, regions: regions) else { return .missing }
                return .ready(rebuilt.comparison, exact: rebuilt.exact)
            }.value
        }
    }

    private func table(_ comparison: PayloadComparison) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sections = comparison.sections.compactMap { section -> PayloadComparison.Section? in
            guard !needle.isEmpty else { return section }
            let rows = section.rows.filter { $0.original.lowercased().contains(needle) || $0.sent.lowercased().contains(needle) }
            return rows.isEmpty ? nil : PayloadComparison.Section(title: section.title, rows: rows, note: section.note)
        }
        return VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Text("原始配置（仅在本机）").frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").hidden()
                Text("发送给 AI").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.rows) { row in ComparisonRow(row: row) }
                        } header: {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                                Text(section.title).font(.callout.weight(.semibold))
                                Text("\(section.rows.count)").font(.caption).foregroundStyle(.secondary)
                                if let note = section.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs + Spacing.xxs)
                            .background(Color.surfaceRaised)
                        }
                    }
                    if sections.isEmpty {
                        Text("没有匹配“\(query)”的内容").font(.callout).foregroundStyle(.secondary).padding(Spacing.lg)
                    }
                }
            }
        }
        .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(Color.separatorLine))
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
    }
}

private struct ComparisonRow: View {
    let row: PayloadComparison.Row

    var body: some View {
        let unchanged = row.original == row.sent
        let withheld = row.sent == "未发送"
        HStack(spacing: Spacing.md) {
            Text(row.original).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
            Group {
                if withheld {
                    Label("未发送", systemImage: "lock.fill").foregroundStyle(.secondary)
                } else {
                    Text(row.sent).foregroundStyle(unchanged ? Color.secondary : Color.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.codeSmall)
        .lineLimit(1).truncationMode(.middle)
        .textSelection(.enabled)
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
        .help(unchanged ? "原样发送（公共分类或内置出口）" : "\(row.original) → \(row.sent)")
    }
}

/// The model's reasoning. While the turn runs it is open and follows the newest text; once the
/// answer arrives it folds into a disclosure the user can reopen.
struct ReasoningView: View {
    let text: String
    let running: Bool
    let source: String
    @State private var expanded = false

    var body: some View {
        if running {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("模型正在思考…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                box(followingEnd: true)
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                box(followingEnd: false)
            } label: {
                Text("模型思考（由 \(source) 提供）").font(.callout)
            }
        }
    }

    private func box(followingEnd: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(Spacing.sm)
            }
            .frame(maxHeight: followingEnd ? 160 : 220)
            .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small))
            .onChange(of: text) { if followingEnd { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { if followingEnd { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .accessibilityLabel("模型思考")
    }
}

/// The domains the model had Veer test: the rule each one hits under the current draft, and
/// the rule sets that contain it.
struct CheckRecordsView: View {
    let records: [CheckRecord]
    let running: Bool
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? true }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(records, id: \.domain) { record in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(record.domain).font(Typography.codeSmall).textSelection(.enabled)
                        if let index = record.ruleIndex, let rule = record.rule {
                            Text(verbatim: "\(record.certain ? "命中" : "可能命中")第 \(index + 1) 条 \(rule)")
                                .font(.caption).foregroundStyle(record.certain ? .secondary : Color.statusWarning).textSelection(.enabled)
                        } else {
                            Text("本机无法确定命中哪一条").font(.caption).foregroundStyle(.secondary)
                        }
                        if let note = record.note { Text(note).font(.caption).foregroundStyle(.tertiary) }
                        if !record.sets.isEmpty {
                            FlowLayout(spacing: Spacing.xs) {
                                ForEach(record.sets, id: \.self) { Tag(text: GeoSiteHit.isBroad($0) ? "\($0)（宽泛）" : $0) }
                            }
                            .help("包含这个域名的 MetaCubeX 规则集")
                        }
                    }
                }
                Text("Veer 用当前草稿的规则在本机逐条匹配，结果已发给 AI。").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small))
        } label: {
            Label("本机检查 \(records.count) 个域名", systemImage: "checklist").font(.callout)
        }
    }
}

/// The searches the model asked for: each query, the rule sets it matched and the pages found.
/// What the local geodata said about the instruction's domains and IPs. Expanded when it holds
/// an IP suggestion the user may want to act on.
struct LookupHintsView: View {
    @Environment(EditorStore.self) private var store
    let hints: LookupHints
    /// Local parsing used the sites' own rule sets; with AI they were sent along.
    let local: Bool
    @State private var expanded: Bool?

    private var suggestsNetwork: Bool { hints.addresses.contains { $0.network != nil && !$0.isPrivate && !$0.isFakeIP } }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? suggestsNetwork }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(hints.domains, id: \.domain) { entry in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.domain).font(Typography.codeSmall).textSelection(.enabled)
                        if entry.ownSet == nil && entry.others.isEmpty && entry.broad.isEmpty {
                            Text("没有规则集包含它，按域名写规则。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            FlowLayout(spacing: Spacing.xs) {
                                if let own = entry.ownSet { Tag(text: "自己的规则集 \(own)", tint: .statusSuccess) }
                                ForEach(entry.others, id: \.self) { Tag(text: $0) }
                                ForEach(entry.broad, id: \.self) { Tag(text: "\($0)（宽泛）") }
                            }
                            if entry.ownSet != nil, local {
                                Text("本地解析用它代替单条 DOMAIN-SUFFIX，覆盖这个网站的全部域名。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ForEach(hints.addresses, id: \.address) { entry in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(entry.address).font(Typography.codeSmall).textSelection(.enabled)
                        if entry.isFakeIP {
                            Text("代理分配的 Fake-IP，不是网站的真实地址。").font(.caption).foregroundStyle(Color.statusWarning)
                        } else if entry.isPrivate {
                            Text("局域网地址。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            if let asn = entry.asn {
                                Text(verbatim: "AS\(asn) \(entry.organization ?? "") · 网段 \(entry.network ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                            if !entry.geoip.isEmpty {
                                FlowLayout(spacing: Spacing.xs) { ForEach(entry.geoip, id: \.self) { Tag(text: "geoip/\($0)") } }
                            }
                            if let network = entry.network {
                                HStack(spacing: Spacing.sm) {
                                    Text("这一轮只写这个地址。").font(.caption).foregroundStyle(.secondary)
                                    Button("按网段 \(network) 分流…") { store.draftInstruction("\(network) 走 ") }
                                        .buttonStyle(.link).foregroundStyle(Color.veerAccent).font(.caption)
                                        .disabled(store.isRunning)
                                        .help("在输入框写好“\(network) 走 ”，再选择出口")
                                }
                            }
                        }
                    }
                }
                Text(local ? "Veer 在本机 MetaCubeX 地理数据中查到。" : "Veer 在本机 MetaCubeX 地理数据中查到，并随指令发给了 AI。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small))
        } label: {
            Label("本机查询 \(hints.domains.count + hints.addresses.count) 项", systemImage: "magnifyingglass.circle").font(.callout)
        }
    }
}

struct SearchRecordsView: View {
    let records: [SearchRecord]
    let running: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || running }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(record.query, systemImage: "magnifyingglass").font(.callout.weight(.medium))
                        if !record.geosite.isEmpty || !record.geoip.isEmpty {
                            FlowLayout(spacing: Spacing.xs) {
                                ForEach(record.geosite + record.geoip.map { "geoip/\($0)" }, id: \.self) { Tag(text: $0) }
                            }
                            .help("MetaCubeX 中已确认存在的规则集")
                        }
                        ForEach(Array(record.web.enumerated()), id: \.offset) { _, result in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                if let url = URL(string: result.url) {
                                    Link(result.title, destination: url).font(.callout).lineLimit(1)
                                } else {
                                    Text(result.title).font(.callout).lineLimit(1)
                                }
                                Text(result.url).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                if !result.snippet.isEmpty {
                                    Text(result.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        if record.web.isEmpty, let note = record.note {
                            Text("网页：\(note)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(record.containing ?? [], id: \.domain) { entry in
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text("包含 \(entry.domain) 的规则集").font(.caption).foregroundStyle(.secondary)
                                if entry.sets.isEmpty {
                                    Text("没有").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    FlowLayout(spacing: Spacing.xs) {
                                        ForEach(entry.sets, id: \.self) { Tag(text: GeoSiteHit.isBroad($0) ? "\($0)（宽泛）" : $0) }
                                    }
                                }
                            }
                            .help("Veer 在本机地理数据中按域名查到")
                        }
                    }
                }
                Text("来源：\(records.first?.source ?? "") 与 MetaCubeX 规则集目录。搜索结果只是参考，最终修改仍需你确认。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.subtleFill, in: RoundedRectangle(cornerRadius: Radius.small))
        } label: {
            Label("联网搜索 \(records.count) 条查询", systemImage: "globe").font(.callout)
        }
    }
}
