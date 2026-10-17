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
                .foregroundStyle(.white)
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
            switch turn.outcome {
            case .running, .note:
                EmptyView()
            case .proposal(let proposal):
                ProposalView(turn: turn, proposal: proposal)
            case .noChange(let text):
                Text(text).foregroundStyle(.secondary)
            case let .clarification(question, suggestions):
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(question).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !suggestions.isEmpty {
                        FlowLayout(spacing: Spacing.sm) {
                            ForEach(suggestions, id: \.self) { option in
                                Chip(text: option) { store.send(followUp(for: option)) }
                            }
                        }
                    }
                }
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

    /// Answering a clarification restates the original request with the chosen exit.
    private func followUp(for option: String) -> String {
        let base = turn.prompt.replacingOccurrences(of: #"走\s*代理|走\s*proxy"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return "\(base) 走 @\(option)"
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
                        Image(systemName: summaryIcon.0).foregroundStyle(summaryIcon.1)
                        Text(summary)
                        Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(summary)，\(expanded ? "已展开" : "已折叠")")
                if expanded {
                    rows.padding(.leading, Spacing.lg)
                    Text("步骤是 Veer 的真实任务状态，不是模型的推理过程。")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, Spacing.lg)
                }
            }
        }
    }

    private var summaryIcon: (String, Color) {
        if turn.steps.contains(where: { $0.state == .failed }) { return ("xmark.circle", .statusFailure) }
        if turn.steps.contains(where: { $0.state == .cancelled }) { return ("minus.circle", .secondary) }
        return ("checkmark", .veerAccent)
    }

    private var summary: String {
        let failed = turn.steps.contains { $0.state == .failed }
        let cancelled = turn.steps.contains { $0.state == .cancelled }
        let head = failed ? "处理失败" : cancelled ? "已停止" : "处理完成"
        let time = turn.duration.map { String(format: " · %.1f 秒", $0) } ?? ""
        return "\(head) · \(turn.steps.filter { $0.state == .done }.count) 步\(time) · \(turn.mode.label)"
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
                    ChangeRow(item: item, accepted: proposal.accepted.contains(item.id), editable: editable) { accepted in
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
                Button("放弃") { store.discard(turnID: turn.id) }
                    .buttonStyle(.bordered).controlSize(.large)
                if proposal.validation.status == .failed {
                    Text("校验未通过，不能写入").font(.callout).foregroundStyle(Color.statusFailure)
                } else if acceptedCount == 0 {
                    Text("至少选择一项").font(.callout).foregroundStyle(.secondary)
                }
            case .undone:
                StatusBadge(kind: .neutral, text: "已撤销")
                if store.current?.redoStack.last == proposal.writtenTo { Button("重做") { store.redo() }.buttonStyle(.link).foregroundStyle(Color.veerAccent) }
            case .written:
                StatusBadge(kind: .success, text: "已写入草稿")
                if store.current?.undoStack.last == proposal.writtenFrom, store.current?.draftText == proposal.writtenTo {
                    Button("撤销") { store.undo() }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
            case .discarded:
                StatusBadge(kind: .neutral, text: "已放弃")
            case .pending, .stale:
                StatusBadge(kind: .warning, text: "已失效 · 草稿已变化，请重新生成")
                Button("重新生成") { store.retry(turnID: turn.id) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
            }
            Button("查看差异") { store.showDiff(for: turn.id) }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
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
            Toggle("接受", isOn: Binding(get: { accepted }, set: { toggle($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.veerAccent)
                .disabled(!editable)
                .accessibilityLabel("\(accessibilityText)，\(accepted ? "已接受" : "已拒绝")")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .opacity(accepted || !editable ? 1 : 0.55)
    }

    @ViewBuilder private var title: some View {
        HStack(spacing: Spacing.sm) {
            Text(item.subject).fontWeight(.medium)
            if item.kind == .removeRule {
                Text("删除规则").foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.secondary)
                Text(targetText).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var targetText: String {
        guard let name = item.targetName else { return "" }
        if name == "DIRECT" { return "直连" }
        if name == "REJECT" { return "拦截" }
        let region = store.regions[name] ?? .unknown
        return region == .unknown ? name : "\(name)（\(region.displayName)·推断）"
    }

    private var detail: String {
        if let provider = item.provider {
            return "规则集 \(provider.sourceLabel) · \(provider.verification.label)"
        }
        return item.rule ?? "\(item.matchType),\(item.match)"
    }

    private var accessibilityText: String {
        item.kind == .removeRule ? "删除 \(item.subject) 的规则" : "\(item.subject) 到 \(targetText)"
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
    let turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("发送给 AI 的内容").font(.headline)
            Text("这是本轮请求中除系统说明外的全部内容。出口名称已替换为匿名标签。")
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
            if let system = turn.sentPayload?.system {
                DisclosureGroup("系统说明（每轮相同，只含匿名出口）") {
                    ScrollView {
                        Text(system).font(Typography.codeSmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                    }
                    .frame(height: 180)
                    .background(Color.codeBackground, in: RoundedRectangle(cornerRadius: Radius.small))
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label("未发送：节点地址、密码、订阅链接、现有规则、真实出口名称", systemImage: "lock.shield")
                Label("你在指令里亲自输入的内容会原样发送（出口名除外），请勿填写密钥", systemImage: "exclamationmark.triangle")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Spacing.xl)
        .frame(width: 560, height: 560)
    }
}
