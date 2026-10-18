import Foundation

/// Runs one instruction through the pipeline: understand → check exits → generate → validate.
/// Step indices match `EditorEngine.stepTitles`; progress reports real task state only.
public struct EditorEngine: Sendable {
    public static let stepTitles = ["理解指令", "检查出口", "生成修改", "校验"]

    public enum Output: Sendable {
        case proposal(plan: EditPlan, items: [ChangeItem], candidate: String, validation: ValidationResult)
        case noChange(String)
        case clarification(String, options: [ClarifyOption])
        case outOfScope(String)
    }

    public enum Progress: Sendable {
        case started(Int)
        case finished(Int, detail: String?)
    }

    public struct Request: Sendable {
        public var prompt: String
        public var draft: ConfigDocument
        public var regions: [String: Region]
        public var useAI: Bool
        public var settings: AISettings
        public var apiKey: String?
        /// Anonymized earlier exchanges, oldest first.
        public var history: [(role: String, content: String)]
        /// Send literal domains/IPs from existing rules instead of placeholders (off by default).
        public var shareRuleLiterals: Bool

        public init(prompt: String, draft: ConfigDocument, regions: [String: Region], useAI: Bool, settings: AISettings, apiKey: String?,
                    history: [(role: String, content: String)] = [], shareRuleLiterals: Bool = false) {
            self.shareRuleLiterals = shareRuleLiterals
            self.prompt = prompt
            self.draft = draft
            self.regions = regions
            self.useAI = useAI
            self.settings = settings
            self.apiKey = apiKey
            self.history = history
        }
    }

    let ai: AIClient
    public let validator: ConfigValidating
    let verifier: RuleSetVerifying

    public init(ai: AIClient = AIClient(), validator: ConfigValidating = MihomoValidator(), verifier: RuleSetVerifying = NetworkRuleSetVerifier()) {
        self.ai = ai
        self.validator = validator
        self.verifier = verifier
    }

    /// The anonymized payload a request would send; shown to the user per turn.
    public static func payload(for request: Request) -> AIRequestPayload {
        let anonymized = AnonymizedConfig.make(document: request.draft, regions: request.regions, shareRuleLiterals: request.shareRuleLiterals)
        return AIRequestPayload(model: request.settings.model, exits: anonymized.context.exits.map(\.label),
                                history: request.history.map { "\($0.role == "user" ? "用户" : "助手")：\($0.content)" },
                                instruction: anonymized.context.anonymize(request.prompt),
                                system: AIClient.systemPrompt(config: anonymized.yaml), config: anonymized.yaml)
    }

    public func run(_ request: Request, progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(0))
        if LocalIntentParser.isOutOfScope(request.prompt) {
            await progress(.finished(0, detail: "超出编辑范围"))
            return .outOfScope(LocalIntentParser.outOfScopeMessage)
        }
        let reply: AssistantReply
        if request.useAI {
            let anonymized = AnonymizedConfig.make(document: request.draft, regions: request.regions, shareRuleLiterals: request.shareRuleLiterals)
            let context = anonymized.context
            let httpRequest = try ai.makeRequest(settings: request.settings, apiKey: request.apiKey,
                                                 system: AIClient.systemPrompt(config: anonymized.yaml),
                                                 history: request.history, prompt: context.anonymize(request.prompt))
            let content = try await ai.complete(httpRequest)
            try Task.checkCancellation()
            reply = try EditPlan.decodeReply(content)
        } else {
            reply = try LocalIntentParser.parse(request.prompt, targets: request.draft.targets, regions: request.regions)
        }
        await progress(.finished(0, detail: request.useAI ? "已由 \(request.settings.model) 解析" : "本地解析"))

        switch reply {
        case let .clarification(question, options):
            let fallback = request.draft.targets.filter { $0.kind == .group }.prefix(4).map { ClarifyOption(label: $0.name) }
            return .clarification(question, options: options.isEmpty ? Array(fallback) : options)
        case let .outOfScope(message):
            return .outOfScope(message)
        case let .plan(plan):
            return try await process(plan, draft: request.draft, progress: progress)
        }
    }

    /// Runs a plan the user built directly (for example from the rule-set sheet): same checks,
    /// same review card, no parsing step.
    public func run(plan: EditPlan, draft: ConfigDocument, progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(0))
        await progress(.finished(0, detail: "手动添加"))
        return try await process(plan, draft: draft, progress: progress)
    }

    func process(_ plan: EditPlan, draft: ConfigDocument, progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(1))
        var exitNames: [String] = []
        for op in plan.operations {
            let id: String?
            switch op {
            case let .route(_, _, target), let .ruleSet(_, target): id = target
            case .removeRule: id = nil
            }
            guard let id else { continue }
            guard let target = draft.target(id: id) else { throw EditorError("修改引用了当前配置中不存在的出口。") }
            if !exitNames.contains(target.name) { exitNames.append(target.name) }
        }
        await progress(.finished(1, detail: exitNames.isEmpty ? "无需出口" : exitNames.joined(separator: "、")))

        await progress(.started(2))
        var result = try PlanApplier.apply(plan, to: draft)
        let newURLs = result.items.compactMap { $0.provider }.filter { !$0.reused }.map(\.url)
        if !newURLs.isEmpty {
            let checks = await verifier.verify(newURLs)
            try Task.checkCancellation()
            let missing = newURLs.filter { checks[$0] == .missing }
            if !missing.isEmpty {
                throw EditorError("规则集地址不存在（404）：\(missing.joined(separator: "、"))。Veer 不会使用推测的地址。\(RuleSetCatalog.findHelp)")
            }
            result = try PlanApplier.apply(plan, to: draft, verification: checks)
        }
        guard result.changed else {
            await progress(.finished(2, detail: "没有变化"))
            return .noChange("这些规则已经是你要的样子，草稿没有变化。")
        }
        await progress(.finished(2, detail: "\(result.items.count) 项修改"))

        await progress(.started(3))
        let validation = await validator.validate(result.candidate)
        try Task.checkCancellation()
        await progress(.finished(3, detail: validation.message))
        return .proposal(plan: plan, items: result.items, candidate: result.candidate, validation: validation)
    }

    /// Re-applies a subset of accepted items and re-validates.
    public func reapply(plan: EditPlan, accepted: Set<Int>, draft: ConfigDocument, previous: [ChangeItem]) async throws -> (candidate: String, items: [ChangeItem], validation: ValidationResult) {
        var checks: [String: RuleSetVerification] = [:]
        for item in previous { if let provider = item.provider { checks[provider.url] = provider.verification } }
        let result = try PlanApplier.apply(plan, to: draft, accepting: accepted, verification: checks)
        let validation = accepted.isEmpty ? ValidationResult(status: .passed, message: "没有选择任何修改") : await validator.validate(result.candidate)
        return (result.candidate, result.items, validation)
    }

    public var validatorVersion: String? { validator.versionDescription }
}
