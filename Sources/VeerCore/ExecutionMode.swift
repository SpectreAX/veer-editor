import Foundation

/// How much the conversation may do without asking, like Claude Code's permission modes.
public enum ExecutionMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case auto, manual, acceptEdits, plan, full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .manual: "手动"
        case .acceptEdits: "自动写入"
        case .plan: "计划"
        case .full: "完整权限"
        }
    }

    public var detail: String {
        switch self {
        case .auto: "Veer 判断风险：只新增或改动分流、校验通过的修改直接写入；删除、新建策略组和宽泛规则集仍由你审阅"
        case .manual: "每项修改都先由你审阅，确认后才写入草稿"
        case .acceptEdits: "通过 Mihomo 校验的修改全部直接写入草稿，可以撤销"
        case .plan: "AI 只分析并给出可选方案，不生成修改；选定方案后再生成修改供你审阅"
        case .full: "AI 遇到不明确的地方自己做合理假设、不再追问，修改直接写入草稿"
        }
    }

    public var symbol: String {
        switch self {
        // Not sparkles or a checkmark: those sit beside it as AI parsing and the change checkboxes.
        case .auto: "a.circle"
        case .manual: "hand.raised"
        case .acceptEdits: "square.and.pencil"
        case .plan: "list.bullet.clipboard"
        case .full: "exclamationmark.shield"
        }
    }

    /// Whether a proposal goes into the draft without review. A failed Mihomo check always waits.
    public func writesAutomatically(items: [ChangeItem], validation: ValidationResult) -> Bool {
        switch self {
        case .manual, .plan: return false
        case .full: return validation.status != .failed
        case .acceptEdits: return validation.status == .passed
        case .auto:
            // Routine edits only: routes and specific rule sets toward existing exits, at most a few.
            guard validation.status == .passed, items.count <= 8 else { return false }
            return items.allSatisfy { item in
                switch item.kind {
                case .route: return true
                case .ruleSet: return !(item.provider.flatMap { MetaCubeXSet(url: $0.url) }.map { GeoSiteHit.isBroad($0.name) } ?? false)
                case .removeRule, .group, .removeProvider: return false
                }
            }
        }
    }

    /// Why a mode that writes on its own left a proposal for review (nil when it would not write anyway).
    public func heldReason(validation: ValidationResult) -> String? {
        switch self {
        case .manual, .plan, .full: nil
        case .auto: "自动模式：含删除、新建策略组、宽泛规则集或较多修改，需要你确认"
        case .acceptEdits: validation.status == .passed ? nil : "自动写入模式：Mihomo 校验没有完成，需要你确认"
        }
    }

    /// Instructions the mode adds to the system prompt.
    var promptSection: String {
        switch self {
        case .plan:
            return """
            # 当前模式：计划

            用户在计划模式：只分析，不要输出修改计划（operations）。用澄清格式：clarification 写出你的分析和建议，options 给出 2 到 3 个可执行的方案，每个方案的 prompt 是一条完整、可直接执行的指令。用户选定方案后，Veer 会按该指令生成修改。


            """
        case .full:
            return """
            # 当前模式：完整权限

            用户授权你自己做合理假设，尽量不要追问：没有指明出口的“走代理”用 MATCH 规则的出口；地区不明确时选最合适的现有地区策略组；同一需求有多种做法时选最常见的一种。把每个假设写进 understanding。只有完全无法执行时才澄清。


            """
        case .auto, .manual, .acceptEdits:
            return ""
        }
    }
}
