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
        /// The model's one-line reading of the instruction.
        case understanding(String)
        /// Reasoning text returned by a reasoning model (deep thinking).
        case reasoning(String)
        /// The first answer was unusable; Veer sent the error back and asked again.
        case retrying(String)
        /// The model asked Veer to search these queries.
        case searching([String])
        /// What the searches found (also sent back to the model).
        case searched([SearchRecord])
        /// What the local geodata says about the instruction's domains and IPs.
        case lookedUp(LookupHints)
        case checking([String])
        /// The results and the message that carried them to the model.
        case checked([CheckRecord], sent: String)
    }

    /// How many times an unusable AI answer is sent back with its error before giving up.
    public static let repairAttempts = 1

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
        /// Lets the model ask for searches; nil when search is off.
        public var search: SearchConfig?
        /// What the conversation may do without asking; shapes the prompt (plan, full).
        public var mode: ExecutionMode = .manual

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
    let searcher: RuleSearching
    /// Local geodata lookups for the instruction's domains and IPs; nil skips them.
    let lookup: InstructionLookup?
    /// Tests domains against the draft when the model asks; nil answers that checking is unavailable.
    let checker: DomainChecker?

    public init(ai: AIClient = AIClient(), validator: ConfigValidating = MihomoValidator(), verifier: RuleSetVerifying = NetworkRuleSetVerifier(),
                searcher: RuleSearching = WebSearchService(), lookup: InstructionLookup? = nil, checker: DomainChecker? = nil) {
        self.lookup = lookup
        self.checker = checker
        self.ai = ai
        self.validator = validator
        self.verifier = verifier
        self.searcher = searcher
    }

    /// The anonymized payload a request would send; shown to the user per turn.
    public static func payload(for request: Request) -> AIRequestPayload {
        let anonymized = AnonymizedConfig.make(document: request.draft, regions: request.regions, shareRuleLiterals: request.shareRuleLiterals)
        var payload = AIRequestPayload(model: request.settings.modelLabel, exits: anonymized.context.exits.map(\.label),
                                       history: request.history.map { "\($0.role == "user" ? "用户" : "助手")：\($0.content)" },
                                       instruction: anonymized.context.anonymize(request.prompt),
                                       system: AIClient.systemPrompt(config: anonymized.yaml, search: request.search != nil, mode: request.mode),
                                       config: anonymized.yaml)
        payload.sourceDigest = AIRequestPayload.digest(request.draft.text)
        payload.shareRuleLiterals = request.shareRuleLiterals
        return payload
    }

    public func run(_ request: Request, progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(0))
        if LocalIntentParser.isOutOfScope(request.prompt) {
            await progress(.finished(0, detail: "超出编辑范围"))
            return .outOfScope(LocalIntentParser.outOfScopeMessage)
        }
        let hints = await lookup?.hints(for: request.prompt, exitNames: request.draft.targets.map(\.name))
        if let hints { await progress(.lookedUp(hints)) }
        guard request.useAI else {
            let reply = try LocalIntentParser.parse(request.prompt, targets: request.draft.targets, regions: request.regions,
                                                    rules: request.draft.rules, ownSets: hints?.ownSets ?? [:])
            await progress(.finished(0, detail: "本地解析"))
            return try await handle(reply, request: request, progress: progress)
        }

        let anonymized = AnonymizedConfig.make(document: request.draft, regions: request.regions, shareRuleLiterals: request.shareRuleLiterals)
        let system = AIClient.systemPrompt(config: anonymized.yaml, search: request.search != nil, mode: request.mode)
        // Lookup results travel with the instruction (and are anonymized with it).
        let prompt = anonymized.context.anonymize(request.prompt + (hints.map { "\n\n" + $0.message } ?? ""))
        let model = request.settings.modelLabel
        var followUps: [(role: String, content: String)] = []
        var attempt = 0
        var searchRounds = 0
        var checkRounds = 0
        while true {
            // Thinking models stream, so their reasoning shows while they work.
            let streaming = request.settings.thinks
            let httpRequest = try ai.makeRequest(settings: request.settings, apiKey: request.apiKey, system: system, history: request.history,
                                                 prompt: prompt, followUps: followUps, stream: streaming)
            let answer = streaming
                ? try await ai.stream(httpRequest) { reasoning in await progress(.reasoning(reasoning)) }
                : try await ai.completeWithReasoning(httpRequest)
            try Task.checkCancellation()
            if !streaming, let reasoning = answer.reasoning, !reasoning.isEmpty { await progress(.reasoning(reasoning)) }
            do {
                let decoded = try EditPlan.decodeReplyWithUnderstanding(answer.content)
                if let understanding = decoded.understanding, !understanding.isEmpty {
                    await progress(.understanding(anonymized.context.restore(understanding)))
                }
                if case let .search(queries) = decoded.reply {
                    // Search, hand the results back, and ask again (at most `maxRounds` times).
                    guard let config = request.search else { throw EditorError("联网搜索未开启，不能请求搜索。请直接输出修改计划或澄清问题。") }
                    guard searchRounds < SearchQueries.maxRounds else { throw EditorError("本轮已经搜索过 \(SearchQueries.maxRounds) 次，不能再搜索。请根据已有结果输出修改计划或澄清问题。") }
                    let checked = SearchQueries.sanitize(queries)
                    guard !checked.accepted.isEmpty else { throw EditorError("搜索词包含配置里的标签、占位符或私有地址，Veer 不会发送。请只用公开的服务或网站名称搜索。") }
                    searchRounds += 1
                    await progress(.searching(checked.accepted))
                    let records = await searcher.search(checked.accepted, config: config)
                    try Task.checkCancellation()
                    await progress(.searched(records))
                    followUps += [("assistant", String(answer.content.prefix(8_000))),
                                  ("user", SearchQueries.message(for: records, refused: checked.refused, lastRound: searchRounds >= SearchQueries.maxRounds))]
                    continue
                }
                if case let .check(raw) = decoded.reply {
                    // Test the domains against the draft and hand the results back (at most `maxRounds` times).
                    guard let checker else { throw EditorError("本机检查不可用。请直接输出修改计划或澄清问题。") }
                    guard checkRounds < DomainChecker.maxRounds else { throw EditorError("本轮已经检查过 \(DomainChecker.maxRounds) 次，不能再检查。请根据已有结果输出修改计划或澄清问题。") }
                    let domains = DomainChecker.sanitize(raw)
                    guard !domains.isEmpty else { throw EditorError("check.domains 里没有有效的域名（例如 i0.hdslb.com），请只列公开域名。") }
                    checkRounds += 1
                    await progress(.checking(domains))
                    let records = await checker.check(domains, draft: request.draft)
                    try Task.checkCancellation()
                    let geodata = await checker.geo?.status().has(.geosite) ?? false
                    let message = DomainChecker.message(for: records, anonymizedRules: anonymized.rules, geodata: geodata,
                                                        lastRound: checkRounds >= DomainChecker.maxRounds)
                    await progress(.checked(records, sent: message))
                    followUps += [("assistant", String(answer.content.prefix(8_000))), ("user", message)]
                    continue
                }
                if request.mode == .plan, case .plan = decoded.reply {
                    throw EditorError("计划模式下不要输出修改计划。请用 clarification 写出分析，用 options 给出 2 到 3 个方案。")
                }
                if attempt == 0 { await progress(.finished(0, detail: "已由 \(model) 解析")) }
                var reply = anonymized.restoringRuleSetNames(in: decoded.reply)
                if case let .clarification(question, options) = reply {
                    // The user sees, and later sends, real exit names, not the model's labels.
                    reply = .clarification(anonymized.context.restore(question), options: options.map {
                        ClarifyOption(label: anonymized.context.restore($0.label), prompt: $0.prompt.map(anonymized.context.restore))
                    })
                }
                return try await handle(reply, request: request, progress: progress)
            } catch let error as EditorError where attempt < Self.repairAttempts {
                // Send the problem back once instead of showing the user an unusable answer.
                attempt += 1
                await progress(.retrying(error.message))
                followUps += [("assistant", String(answer.content.prefix(8_000))),
                              ("user", "你上一次的输出无法使用：\(error.message)\n请根据这个问题修正，重新输出一个完整、符合格式的 JSON 对象，不要输出其他内容。")]
            }
        }
    }

    func handle(_ reply: AssistantReply, request: Request, progress: @Sendable (Progress) async -> Void) async throws -> Output {
        switch reply {
        case let .clarification(question, options):
            // Exit buttons only help when the question is about where traffic should go.
            let aboutExits = question.matches(#"出口|策略组|节点|走哪|哪个地区|哪一个地区"#)
            return .clarification(question, options: options.isEmpty && aboutExits ? Self.suggestedExits(for: request) : options)
        case let .outOfScope(message):
            return .outOfScope(message)
        case let .plan(plan):
            return try await process(plan, draft: request.draft, regions: request.regions, progress: progress)
        case .search:
            // Searches are answered inside the AI loop; one reaching here was not allowed.
            throw EditorError("AI 请求了联网搜索，但本轮不能再搜索。请换一种说法或开启联网搜索。")
        case .check:
            throw EditorError("AI 请求了本机检查，但本轮不能再检查。请换一种说法再试。")
        }
    }

    /// Exits to offer when the model asked without options: groups in the regions the instruction
    /// mentions first, then other regional groups, never just the first groups in the file.
    static func suggestedExits(for request: Request) -> [ClarifyOption] {
        let mentioned = Region.allCases.filter { $0.instructionPattern.map(request.prompt.matches) ?? false }
        let groups = request.draft.targets.filter { $0.kind == .group }
        func region(_ target: Target) -> Region { request.regions[target.name] ?? Region.infer(from: target.name) }
        let inMentioned = groups.filter { mentioned.contains(region($0)) }
        let regional = groups.filter { region($0) != .unknown && !mentioned.contains(region($0)) }
        let pool = inMentioned.isEmpty ? (regional.isEmpty ? groups : regional) : inMentioned
        return pool.prefix(6).map { ClarifyOption(label: $0.name) }
    }

    /// Runs a plan the user built directly (for example from the rule-set sheet): same checks,
    /// same review card, no parsing step.
    public func run(plan: EditPlan, draft: ConfigDocument, regions: [String: Region] = [:], progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(0))
        await progress(.finished(0, detail: "手动添加"))
        return try await process(plan, draft: draft, regions: regions, progress: progress)
    }

    func process(_ plan: EditPlan, draft: ConfigDocument, regions: [String: Region], progress: @Sendable (Progress) async -> Void) async throws -> Output {
        await progress(.started(1))
        var exitNames: [String] = []
        for op in plan.operations {
            let id: String?
            switch op {
            case let .route(_, _, target), let .ruleSet(_, target): id = target
            case .removeRule: id = nil
            case .group(let group):
                exitNames.append("新建 \(group.name)")
                id = nil
            }
            guard let id else { continue }
            if plan.operations.contains(where: { if case .group(let group) = $0 { group.id == id } else { false } }) { continue }
            guard let target = draft.target(id: id) else { throw EditorError("修改引用了当前配置中不存在的出口。") }
            if !exitNames.contains(target.name) { exitNames.append(target.name) }
        }
        await progress(.finished(1, detail: exitNames.isEmpty ? "无需出口" : exitNames.joined(separator: "、")))

        await progress(.started(2))
        var result = try PlanApplier.apply(plan, to: draft, regions: regions)
        let newURLs = result.items.compactMap { $0.provider }.filter { !$0.reused }.map(\.url)
        if !newURLs.isEmpty {
            let checks = await verifier.verify(newURLs)
            try Task.checkCancellation()
            let missing = newURLs.filter { checks[$0] == .missing }
            if !missing.isEmpty {
                throw EditorError("规则集地址不存在（404）：\(missing.joined(separator: "、"))。Veer 不会使用推测的地址。\(RuleSetCatalog.findHelp)")
            }
            result = try PlanApplier.apply(plan, to: draft, regions: regions, verification: checks)
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
    public func reapply(plan: EditPlan, accepted: Set<Int>, draft: ConfigDocument, regions: [String: Region] = [:], previous: [ChangeItem]) async throws -> (candidate: String, items: [ChangeItem], validation: ValidationResult) {
        var checks: [String: RuleSetVerification] = [:]
        for item in previous { if let provider = item.provider { checks[provider.url] = provider.verification } }
        let result = try PlanApplier.apply(plan, to: draft, regions: regions, accepting: accepted, verification: checks)
        let validation = accepted.isEmpty ? ValidationResult(status: .passed, message: "没有选择任何修改") : await validator.validate(result.candidate)
        return (result.candidate, result.items, validation)
    }

    public var validatorVersion: String? { validator.versionDescription }
}
