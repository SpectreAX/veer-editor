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

/// How a model does deep thinking. It decides which model choices exist and what the request sends.
public enum ThinkingStyle: String, Sendable, Codable {
    /// Cannot think; only the normal choice is offered.
    case none
    /// Always reasons (deepseek-reasoner, o4-mini, R1, gemini-2.5-pro); only the thinking choice is offered.
    case intrinsic
    /// GPT-5 family: `reasoning_effort` minimal (normal) or medium (thinking).
    case openAIEffort
    /// Claude: `thinking: {type: enabled, budget_tokens}` when thinking.
    case anthropic
    /// Gemini 2.5 Flash: `thinkingConfig.thinkingBudget` 0 (normal) or dynamic (thinking).
    case gemini
    /// GLM-4.5 / 4.6: `thinking: {type: enabled|disabled}`.
    case zhipu

    /// Whether a normal and a thinking choice are both offered for the same model.
    public var switchable: Bool { self != .none && self != .intrinsic }
}

/// One entry of the model menu: a model, plus whether deep thinking is on.
public struct ModelChoice: Sendable, Hashable, Identifiable {
    public let model: String
    public let thinking: Bool
    public init(model: String, thinking: Bool) {
        self.model = model
        self.thinking = thinking
    }
    public var id: String { model + (thinking ? "#thinking" : "") }
    public var title: String { thinking ? "\(model)（深度思考）" : model }
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
        case .deepSeek: [("deepseek-chat", .none), ("deepseek-reasoner", .intrinsic)]
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
        return .none
    }

    /// Menu entries for one model.
    public func choices(for model: String) -> [ModelChoice] {
        switch thinkingStyle(for: model) {
        case .none: [ModelChoice(model: model, thinking: false)]
        case .intrinsic: [ModelChoice(model: model, thinking: true)]
        default: [ModelChoice(model: model, thinking: false), ModelChoice(model: model, thinking: true)]
        }
    }
}

public struct AISettings: Sendable, Codable, Equatable {
    public var provider: AIProvider
    public var baseURL: String
    public var model: String
    /// Deep thinking for models that can switch it; ignored for the others.
    public var thinking: Bool
    /// The service's model list, from "获取模型列表".
    public var fetchedModels: [String]
    /// Pre-2026-10-19 settings stored a separate reasoning model; used once to migrate.
    public private(set) var legacyReasoningModel: String?

    public init(provider: AIProvider = .deepSeek, baseURL: String? = nil, model: String? = nil, thinking: Bool = false) {
        self.provider = provider
        self.baseURL = baseURL ?? provider.baseURL
        self.model = model ?? provider.defaultModel
        self.thinking = thinking
        self.fetchedModels = []
    }

    enum CodingKeys: String, CodingKey { case preset, baseURL, model, thinking, fetchedModels, reasoningModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decode(AIProvider.self, forKey: .preset)) ?? .custom
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? provider.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? provider.defaultModel
        thinking = try container.decodeIfPresent(Bool.self, forKey: .thinking) ?? false
        fetchedModels = try container.decodeIfPresent([String].self, forKey: .fetchedModels) ?? []
        if !container.contains(.thinking) {
            legacyReasoningModel = try container.decodeIfPresent(String.self, forKey: .reasoningModel)
                ?? provider.catalog.first { $0.style == .intrinsic }?.model ?? ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .preset)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(thinking, forKey: .thinking)
        try container.encode(fetchedModels, forKey: .fetchedModels)
    }

    /// Settings saved before thinking became a model choice. `deepThinking` was the old toggle.
    public mutating func migrateLegacy(deepThinking: Bool) {
        defer { legacyReasoningModel = nil }
        guard let legacy = legacyReasoningModel, deepThinking else { return }
        if !legacy.isEmpty { model = legacy }
        thinking = true
    }

    public var thinkingStyle: ThinkingStyle { provider.thinkingStyle(for: model) }

    /// Whether this request reasons: always for reasoning models, on request for switchable ones.
    public var thinks: Bool {
        switch thinkingStyle {
        case .none: false
        case .intrinsic: true
        default: thinking
        }
    }

    public var choice: ModelChoice { ModelChoice(model: model, thinking: thinks) }

    public mutating func select(_ choice: ModelChoice) {
        model = choice.model
        thinking = choice.thinking
    }

    /// Catalog models, then fetched ones, then the current model if it is in neither.
    public var choices: [ModelChoice] { choices(includingFetched: true) }

    public func choices(includingFetched: Bool) -> [ModelChoice] {
        var models = provider.catalog.map(\.model)
        if includingFetched { models += fetchedModels.filter { !models.contains($0) } }
        if !model.isEmpty && !models.contains(model) { models.append(model) }
        return models.flatMap(provider.choices(for:))
    }

    /// "deepseek-reasoner · 深度思考", shown in the composer and on each turn.
    public var modelLabel: String { thinks ? "\(model) · 深度思考" : model }
}
