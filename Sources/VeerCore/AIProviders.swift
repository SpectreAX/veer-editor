import Foundation

/// Wire format of an AI service.
public enum AIAPIFormat: String, Sendable, Codable {
    /// `POST {base}/chat/completions` (OpenAI and the many services compatible with it).
    case openAI
    /// Anthropic Messages API, `POST {base}/messages`.
    case anthropic
    /// Google Gemini API, `POST {base}/models/{model}:generateContent`.
    case gemini
}

/// How hard the model thinks before answering.
public enum ThinkingLevel: String, Sendable, Codable, CaseIterable, Identifiable {
    case off, low, medium, high, max
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "不思考"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .max: "最高"
        }
    }
}

/// How a model does deep thinking: which strengths it offers and what the request sends.
public enum ThinkingStyle: String, Sendable, Codable {
    /// Cannot think.
    case none
    /// Always reasons at its own strength (o4-mini, R1, kimi-k2-thinking, gemini-2.5-pro).
    case intrinsic
    /// DeepSeek V4: `thinking.type` enabled/disabled and `reasoning_effort` low/high/max. Thinks by default.
    case deepSeek
    /// GPT-5 family: `reasoning_effort` minimal/low/medium/high.
    case openAIEffort
    /// Claude: `thinking: {type: enabled, budget_tokens}`.
    case anthropic
    /// Gemini 2.5 Flash: `thinkingConfig.thinkingBudget`.
    case gemini
    /// GLM-4.5 / 4.6: `thinking.type` enabled/disabled.
    case zhipu

    /// Strengths the user can pick, weakest first.
    public var levels: [ThinkingLevel] {
        switch self {
        case .none: [.off]
        case .intrinsic: [.high]
        case .deepSeek: [.off, .low, .high, .max]
        case .openAIEffort, .anthropic, .gemini: [.off, .low, .medium, .high]
        case .zhipu: [.off, .high]
        }
    }

    /// Whether the user can change the strength.
    public var adjustable: Bool { levels.count > 1 }

    /// The supported level closest to `level`; "off" stays off when the model can turn thinking off.
    public func resolve(_ level: ThinkingLevel) -> ThinkingLevel {
        if levels.contains(level) { return level }
        if level == .off { return levels.contains(.off) ? .off : levels[0] }
        let all = ThinkingLevel.allCases
        let index = all.firstIndex(of: level)!
        return levels.filter { $0 != .off }.min { a, b in
            let da = abs(all.firstIndex(of: a)! - index), db = abs(all.firstIndex(of: b)! - index)
            return da == db ? all.firstIndex(of: a)! > all.firstIndex(of: b)! : da < db
        } ?? levels[0]
    }

    /// Menu title of a level; on/off-only models say "开启".
    public func title(of level: ThinkingLevel) -> String {
        levels.count == 2 && level != .off ? "开启" : level.title
    }
}

/// Supported AI services. Raw values are stored in settings; keep them stable.
public enum AIProvider: String, Sendable, Codable, CaseIterable, Identifiable {
    case openAI, anthropic, gemini, deepSeek, openRouter, qwen, moonshot, zhipu, siliconFlow, xai, ollama, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .qwen: "通义千问（阿里云百炼）"
        case .moonshot: "Kimi（月之暗面）"
        case .zhipu: "智谱 GLM"
        case .siliconFlow: "硅基流动 SiliconFlow"
        case .xai: "xAI Grok"
        case .ollama: "Ollama（本机）"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }

    public var format: AIAPIFormat {
        switch self {
        case .anthropic: .anthropic
        case .gemini: .gemini
        default: .openAI
        }
    }

    public var baseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: "https://api.moonshot.cn/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .xai: "https://api.x.ai/v1"
        case .ollama: "http://127.0.0.1:11434/v1"
        case .custom: ""
        }
    }

    public var needsKey: Bool { self != .ollama }

    /// Suggested models, first is the default. Users can fetch the service's full list.
    public var catalog: [(model: String, style: ThinkingStyle)] {
        switch self {
        case .openAI: [("gpt-4.1-mini", .none), ("gpt-4.1", .none), ("gpt-5-mini", .openAIEffort), ("o4-mini", .intrinsic)]
        case .anthropic: [("claude-sonnet-5-5", .anthropic), ("claude-haiku-5-5", .anthropic), ("claude-opus-5-5", .anthropic)]
        case .gemini: [("gemini-2.5-flash", .gemini), ("gemini-2.5-flash-lite", .gemini), ("gemini-2.5-pro", .intrinsic)]
        case .deepSeek: [("deepseek-flash", .deepSeek), ("deepseek-v4-pro", .deepSeek)]
        case .openRouter: [("openai/gpt-4.1-mini", .none), ("deepseek/deepseek-chat", .none), ("google/gemini-2.5-flash", .none), ("deepseek/deepseek-r1", .intrinsic)]
        case .qwen: [("qwen-plus", .none), ("qwen-max", .none), ("qwen-turbo", .none)]
        case .moonshot: [("kimi-k2-turbo-preview", .none), ("kimi-k2-thinking", .intrinsic)]
        case .zhipu: [("glm-4.6", .zhipu), ("glm-4.5-air", .zhipu)]
        case .siliconFlow: [("deepseek-ai/DeepSeek-V3", .none), ("Qwen/Qwen2.5-72B-Instruct", .none), ("deepseek-ai/DeepSeek-R1", .intrinsic)]
        case .xai: [("grok-3", .none), ("grok-4", .intrinsic)]
        case .ollama: [("qwen2.5:7b", .none), ("deepseek-r1:8b", .intrinsic)]
        case .custom: []
        }
    }

    public var defaultModel: String { catalog.first?.model ?? "" }

    /// Retired model ids and what replaces them. DeepSeek stopped serving `deepseek-chat` and
    /// `deepseek-reasoner` on 2026-07-24; they were Flash without and with thinking.
    public func replacement(for model: String) -> (model: String, level: ThinkingLevel)? {
        guard self == .deepSeek else { return nil }
        switch model {
        case "deepseek-chat": return ("deepseek-flash", .off)
        case "deepseek-reasoner": return ("deepseek-flash", .high)
        default: return nil
        }
    }

    /// Thinking style of any model id, including ones fetched from the service or typed by hand.
    public func thinkingStyle(for model: String) -> ThinkingStyle {
        if let known = catalog.first(where: { $0.model == model }) { return known.style }
        let name = model.lowercased()
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        if tail.range(of: #"(reasoner|thinking|qwq|(^|[-_:])r1([-_:.]|$)|^o[1-9]([-_]|$)|^gemini-[0-9.]+-pro|^grok-4)"#, options: .regularExpression) != nil {
            return .intrinsic
        }
        switch format {
        case .anthropic: return tail.hasPrefix("claude-3-5") || tail.hasPrefix("claude-3-haiku") || tail.hasPrefix("claude-3-opus") ? .none : .anthropic
        case .gemini: return tail.range(of: #"^gemini-(2\.5|[3-9])"#, options: .regularExpression) != nil ? .gemini : .none
        case .openAI: break
        }
        if self == .openAI && tail.hasPrefix("gpt-5") && !tail.contains("chat") { return .openAIEffort }
        if self == .zhipu && tail.range(of: #"^glm-4\.[5-9]"#, options: .regularExpression) != nil { return .zhipu }
        if self == .deepSeek && tail.hasPrefix("deepseek-") { return .deepSeek }
        return .none
    }
}

public struct AISettings: Sendable, Codable, Equatable {
    public var provider: AIProvider
    public var baseURL: String
    public var model: String
    /// Requested thinking strength; models that cannot honour it use the closest one (`effectiveLevel`).
    public var thinkingLevel: ThinkingLevel
    /// The service's model list, from "从服务获取".
    public var fetchedModels: [String]
    /// Pre-2026-10-19 settings stored a separate reasoning model; used once to migrate.
    public private(set) var legacyReasoningModel: String?

    public init(provider: AIProvider = .deepSeek, baseURL: String? = nil, model: String? = nil, thinkingLevel: ThinkingLevel = .off) {
        self.provider = provider
        self.baseURL = baseURL ?? provider.baseURL
        self.model = model ?? provider.defaultModel
        self.thinkingLevel = thinkingLevel
        self.fetchedModels = []
        replaceRetiredModel()
    }

    enum CodingKeys: String, CodingKey { case preset, baseURL, model, thinkingLevel, thinking, fetchedModels, reasoningModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decode(AIProvider.self, forKey: .preset)) ?? .custom
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? provider.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? provider.defaultModel
        fetchedModels = try container.decodeIfPresent([String].self, forKey: .fetchedModels) ?? []
        if let level = try? container.decode(ThinkingLevel.self, forKey: .thinkingLevel) {
            thinkingLevel = level
        } else if let thinking = try container.decodeIfPresent(Bool.self, forKey: .thinking) {
            // 2026-10-19 builds stored an on/off flag; reasoning models were always on.
            let style = provider.thinkingStyle(for: model)
            thinkingLevel = thinking || style == .intrinsic ? .high : .off
        } else {
            thinkingLevel = .off
            legacyReasoningModel = try container.decodeIfPresent(String.self, forKey: .reasoningModel)
                ?? provider.catalog.first { $0.style == .intrinsic }?.model ?? ""
        }
        replaceRetiredModel()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .preset)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(thinkingLevel, forKey: .thinkingLevel)
        try container.encode(fetchedModels, forKey: .fetchedModels)
    }

    /// Settings saved before thinking became part of the model choice. `deepThinking` was the old toggle.
    public mutating func migrateLegacy(deepThinking: Bool) {
        defer { legacyReasoningModel = nil }
        guard let legacy = legacyReasoningModel, deepThinking else { return }
        if !legacy.isEmpty { model = legacy }
        thinkingLevel = .high
        replaceRetiredModel()
    }

    private mutating func replaceRetiredModel() {
        guard let replacement = provider.replacement(for: model) else { return }
        model = replacement.model
        if thinkingLevel == .off || replacement.level == .off { thinkingLevel = replacement.level }
        fetchedModels.removeAll { provider.replacement(for: $0) != nil }
    }

    public var thinkingStyle: ThinkingStyle { provider.thinkingStyle(for: model) }

    /// The strength actually sent for the current model.
    public var effectiveLevel: ThinkingLevel { thinkingStyle.resolve(thinkingLevel) }

    /// Whether this request reasons.
    public var thinks: Bool { effectiveLevel != .off }

    /// Catalog models, then fetched ones, then the current model if it is in neither.
    public var models: [String] { models(includingFetched: true) }

    public func models(includingFetched: Bool) -> [String] {
        var models = provider.catalog.map(\.model)
        if includingFetched { models += fetchedModels.filter { !models.contains($0) } }
        if !model.isEmpty && !models.contains(model) { models.append(model) }
        return models
    }

    /// Selects a model; a retired id is replaced with its successor.
    public mutating func select(model: String) {
        self.model = model
        replaceRetiredModel()
    }

    /// "深度思考 · 高" for adjustable models, "深度思考" for reasoning models, nil when not thinking.
    public var thinkingLabel: String? {
        guard thinks else { return nil }
        return thinkingStyle.adjustable ? "深度思考 · \(thinkingStyle.title(of: effectiveLevel))" : "深度思考"
    }

    /// "deepseek-flash · 深度思考 · 高", shown in the composer and on each turn.
    public var modelLabel: String { thinkingLabel.map { "\(model) · \($0)" } ?? model }
}
