import CryptoKit
import Foundation

/// Classified AI failures; the UI maps each to a recovery action.
public enum AIFailure: Error, Equatable, Sendable {
    case missingKey
    case invalidEndpoint(String)
    case network
    case timeout
    case unauthorized(Int)
    case rateLimited
    case server(Int)
    case http(Int)
    /// 4xx with the service's own explanation (wrong model name, bad parameter).
    case rejected(Int, String)
    case invalidResponse(String)
    case cancelled

    public var message: String {
        switch self {
        case .missingKey: "还没有设置 AI 服务的 API Key。"
        case .invalidEndpoint(let reason): reason
        case .network: "无法连接 AI 服务，请检查网络与服务地址。"
        case .timeout: "AI 服务长时间没有响应（不思考 60 秒，深度思考 180 秒，最高强度 300 秒）。"
        case .unauthorized(let code): "AI 服务拒绝了请求（HTTP \(code)），请检查 API Key 与模型权限。"
        case .rateLimited: "AI 服务限流或额度不足（HTTP 429），请稍后重试。"
        case .server(let code): "AI 服务暂时出错（HTTP \(code)），可以重试。"
        case .http(let code): "AI 服务返回 HTTP \(code)，请检查地址和模型名称。"
        case let .rejected(code, detail): "AI 服务返回 HTTP \(code)：\(detail)。请检查地址和模型名称。"
        case .invalidResponse(let reason): reason
        case .cancelled: "已停止。"
        }
    }

    public var opensSettings: Bool {
        switch self {
        case .missingKey, .invalidEndpoint, .unauthorized, .http, .rejected: true
        default: false
        }
    }
}

/// One anonymized request, kept so the user can inspect exactly what was sent.
public struct AIRequestPayload: Sendable, Codable, Hashable {
    public let model: String
    public let exits: [String]
    public let history: [String]
    public let instruction: String
    /// The full system instructions sent with the request.
    public var system: String?
    /// The anonymized configuration YAML included with the request.
    public var config: String?
    /// SHA-256 of the draft the configuration was made from, to find it again for the comparison view.
    public var sourceDigest: String?
    /// Whether literal domains and IPs were sent as they are.
    public var shareRuleLiterals: Bool?

    public init(model: String, exits: [String], history: [String], instruction: String, system: String? = nil, config: String? = nil) {
        self.model = model
        self.exits = exits
        self.history = history
        self.instruction = instruction
        self.system = system
        self.config = config
    }

    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var readable: String {
        var text = "模型：\(model)\n\n"
        if let config {
            text += "匿名配置（YAML）：\n" + config
        } else {
            text += "出口表：\n" + exits.map { "· \($0)" }.joined(separator: "\n")
        }
        if !history.isEmpty { text += "\n\n此前对话（已匿名）：\n" + history.map { "· \($0)" }.joined(separator: "\n") }
        text += "\n\n指令：\n\(instruction)"
        return text
    }
}

public protocol AITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport that refuses redirects and caps the body at 512 KB.
public final class URLSessionTransport: NSObject, AITransport, URLSessionTaskDelegate, @unchecked Sendable {
    public static let maxBytes = 512 * 1024
    lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIFailure.invalidResponse("AI 服务返回了无法识别的响应。") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw AIFailure.invalidResponse("AI 服务响应超过 512 KB 限制，请缩短指令后重试。") }
        }
        return (data, http)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}


/// A service request plus the wire format needed to read its answer.
public struct AIRequest: Sendable {
    public let urlRequest: URLRequest
    public let format: AIAPIFormat
}

public struct AIClient: Sendable {
    let transport: AITransport
    public init(transport: AITransport = URLSessionTransport()) { self.transport = transport }

    // MARK: Endpoints

    /// Checks a base address: HTTPS, or HTTP on this Mac; no credentials, query or fragment.
    static func validatedBase(_ baseURL: String) throws -> URLComponents {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces)), let host = components.host, let scheme = components.scheme else {
            throw AIFailure.invalidEndpoint("AI 服务地址无效。")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw AIFailure.invalidEndpoint("AI 服务地址必须是 HTTPS，或本机的 HTTP 地址。")
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIFailure.invalidEndpoint("AI 服务地址不能包含用户名、密码或查询参数。")
        }
        components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        return components
    }

    static func url(_ baseURL: String, appending path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = try validatedBase(baseURL)
        components.path += path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AIFailure.invalidEndpoint("AI 服务地址无效。") }
        return url
    }

    /// The OpenAI-compatible chat endpoint for a base address.
    public static func endpoint(for baseURL: String) throws -> URL {
        try url(baseURL, appending: "/chat/completions")
    }

    static func authorize(_ request: inout URLRequest, format: AIAPIFormat, apiKey: String?) {
        guard let apiKey, !apiKey.isEmpty else { return }
        switch format {
        case .openAI: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic: request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        case .gemini: request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        if format == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
    }

    // MARK: Requests

    public func makeRequest(settings: AISettings, apiKey: String?, system: String, history: [(role: String, content: String)], prompt: String,
                            followUps: [(role: String, content: String)] = []) throws -> AIRequest {
        if settings.provider.needsKey && (apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty { throw AIFailure.missingKey }
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw AIFailure.invalidEndpoint("请选择或填写模型。") }
        let format = settings.provider.format
        let style = settings.thinkingStyle
        let level = settings.effectiveLevel
        let thinks = level != .off
        let turns = history + [("user", prompt)] + followUps

        let url: URL
        var body: [String: Any]
        switch format {
        case .openAI:
            url = try Self.endpoint(for: settings.baseURL)
            body = ["model": model, "stream": false,
                    "messages": [["role": "system", "content": system]] + turns.map { ["role": $0.role, "content": $0.content] }]
            switch (style, thinks) {
            case (.openAIEffort, _):
                // GPT-5 family accepts only the default temperature.
                body["reasoning_effort"] = thinks ? level.rawValue : "minimal"
                body["response_format"] = ["type": "json_object"]
            case (_, true):
                // Reasoning is slow, and several services ignore or reject temperature and JSON mode.
                if style == .zhipu { body["thinking"] = ["type": "enabled"] }
                if style == .deepSeek {
                    body["thinking"] = ["type": "enabled"]
                    body["reasoning_effort"] = level.rawValue
                }
            case (_, false):
                // DeepSeek V4 and GLM think unless told not to.
                if style == .zhipu || style == .deepSeek { body["thinking"] = ["type": "disabled"] }
                body["temperature"] = 0
                body["response_format"] = ["type": "json_object"]
            }
        case .anthropic:
            url = try Self.url(settings.baseURL, appending: "/messages")
            let budget = [ThinkingLevel.low: 2_048, .medium: 8_000, .high: 16_000, .max: 32_000][level] ?? 0
            body = ["model": model, "system": system, "max_tokens": budget + 4_096,
                    "messages": Self.alternating(turns).map { ["role": $0.role, "content": $0.content] }]
            if thinks { body["thinking"] = ["type": "enabled", "budget_tokens": budget] } else { body["temperature"] = 0 }
        case .gemini:
            let path = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) else {
                throw AIFailure.invalidEndpoint("模型名称无效。")
            }
            url = try Self.url(settings.baseURL, appending: "/models/\(escaped):generateContent")
            var generation: [String: Any] = ["responseMimeType": "application/json"]
            if !thinks { generation["temperature"] = 0 }
            switch style {
            case .gemini:
                // -1 lets the model decide how much to think.
                let budget = [ThinkingLevel.low: 1_024, .medium: 8_192, .high: -1, .max: -1][level] ?? 0
                generation["thinkingConfig"] = thinks ? ["thinkingBudget": budget, "includeThoughts": true] : ["thinkingBudget": 0]
            case .intrinsic: generation["thinkingConfig"] = ["includeThoughts": true]
            default: break
            }
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": Self.alternating(turns).map { ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]] },
                    "generationConfig": generation]
        }

        var request = URLRequest(url: url, timeoutInterval: level == .max ? 300 : thinks ? 180 : 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.authorize(&request, format: format, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return AIRequest(urlRequest: request, format: format)
    }

    /// Claude and Gemini need user/assistant turns to alternate, starting with the user.
    static func alternating(_ turns: [(role: String, content: String)]) -> [(role: String, content: String)] {
        var result: [(role: String, content: String)] = []
        for turn in turns {
            if result.isEmpty && turn.role != "user" { continue }
            if let last = result.last, last.role == turn.role {
                result[result.count - 1].content += "\n\n" + turn.content
            } else {
                result.append(turn)
            }
        }
        return result
    }

    // MARK: Responses

    /// Sends one request and returns the assistant message content.
    public func complete(_ request: AIRequest) async throws -> String {
        try await completeWithReasoning(request).content
    }

    /// Content plus the model's reasoning when the service returns it (DeepSeek `reasoning_content`,
    /// OpenRouter `reasoning`, Claude thinking blocks, Gemini thought parts, `<think>` tags).
    public func completeWithReasoning(_ request: AIRequest) async throws -> (content: String, reasoning: String?) {
        let data = try await send(request.urlRequest, format: request.format)
        return try Self.parse(data, format: request.format)
    }

    func send(_ request: URLRequest, format: AIAPIFormat) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let failure as AIFailure {
            throw failure
        } catch is CancellationError {
            throw AIFailure.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw AIFailure.cancelled
            case .timedOut: throw AIFailure.timeout
            case .httpTooManyRedirects, .redirectToNonExistentLocation: throw AIFailure.invalidResponse("AI 服务返回了重定向，Veer 不会跟随。请检查服务地址。")
            default: throw AIFailure.network
            }
        } catch {
            throw AIFailure.network
        }
        let detail = Self.errorMessage(data)
        switch response.statusCode {
        case 200..<300: return data
        case 300..<400: throw AIFailure.invalidResponse("AI 服务返回了重定向，Veer 不会跟随。请检查服务地址。")
        case 401, 403: throw AIFailure.unauthorized(response.statusCode)
        case 400 where format == .gemini && (detail?.localizedCaseInsensitiveContains("api key") ?? false): throw AIFailure.unauthorized(400)
        case 429: throw AIFailure.rateLimited
        case 500...: throw AIFailure.server(response.statusCode)
        default:
            if let detail { throw AIFailure.rejected(response.statusCode, detail) }
            throw AIFailure.http(response.statusCode)
        }
    }

    /// `{"error":{"message":…}}`, the shape OpenAI, Claude and Gemini all use.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? (object["error"] as? String) ?? (object["message"] as? String)
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }

    static let incomplete = AIFailure.invalidResponse("AI 的回答没有完整结束，请缩短指令或检查模型设置后重试。")
    static let unreadable = AIFailure.invalidResponse("AI 服务返回了无法读取的响应，请重试。")

    static func parse(_ data: Data, format: AIAPIFormat) throws -> (content: String, reasoning: String?) {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unreadable }
        var content = ""
        var reasoning: String?
        switch format {
        case .openAI:
            guard let choice = (reply["choices"] as? [[String: Any]])?.first else { throw unreadable }
            if let finish = choice["finish_reason"] as? String, finish != "stop" { throw incomplete }
            let message = choice["message"] as? [String: Any]
            content = message?["content"] as? String ?? ""
            reasoning = (message?["reasoning_content"] as? String) ?? (message?["reasoning"] as? String)
        case .anthropic:
            guard let blocks = reply["content"] as? [[String: Any]] else { throw unreadable }
            if reply["stop_reason"] as? String == "max_tokens" { throw incomplete }
            content = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let thoughts = blocks.filter { $0["type"] as? String == "thinking" }.compactMap { $0["thinking"] as? String }
            reasoning = thoughts.isEmpty ? nil : thoughts.joined(separator: "\n\n")
        case .gemini:
            guard let candidate = (reply["candidates"] as? [[String: Any]])?.first else {
                if let blocked = (reply["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
                    throw AIFailure.invalidResponse("AI 服务拒绝回答（\(blocked)），请换一种说法。")
                }
                throw unreadable
            }
            switch candidate["finishReason"] as? String {
            case nil, "STOP": break
            case "MAX_TOKENS": throw incomplete
            case let reason?: throw AIFailure.invalidResponse("AI 服务拒绝回答（\(reason)），请换一种说法。")
            }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            content = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
            let thoughts = parts.filter { $0["thought"] as? Bool == true }.compactMap { $0["text"] as? String }
            reasoning = thoughts.isEmpty ? nil : thoughts.joined(separator: "\n\n")
        }
        let split = splitThinkTags(content)
        content = split.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if reasoning == nil || reasoning?.isEmpty == true { reasoning = split.reasoning }
        guard !content.isEmpty, content.count <= 100_000 else { throw AIFailure.invalidResponse("AI 返回的内容为空或超过长度限制。") }
        return (content, reasoning.map { String($0.prefix(20_000)) })
    }

    /// Open models (R1, QwQ, Qwen3 on Ollama) put their reasoning in `<think>…</think>` before the answer.
    static func splitThinkTags(_ text: String) -> (content: String, reasoning: String?) {
        guard let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
            return (text, nil)
        }
        let thought = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(text[..<open.lowerBound]) + String(text[close.upperBound...]), thought.isEmpty ? nil : thought)
    }

    // MARK: Connection test and model list

    /// Minimal request with no configuration data: confirms key, model and JSON output work.
    public func testConnection(settings: AISettings, apiKey: String?) async throws {
        let request = try makeRequest(settings: settings, apiKey: apiKey, system: "Reply with the JSON object {\"ok\":true} and nothing else.", history: [], prompt: "ping")
        let content = try await complete(request)
        guard content.contains("ok") else { throw AIFailure.invalidResponse("AI 服务可以连接，但没有按 JSON 格式回答。请换一个模型。") }
    }

    /// Chat models the service offers, for the model menu. Sends no configuration data.
    public func listModels(settings: AISettings, apiKey: String?) async throws -> [String] {
        let format = settings.provider.format
        if settings.provider.needsKey && (apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty { throw AIFailure.missingKey }
        let url: URL
        switch format {
        case .openAI: url = try Self.url(settings.baseURL, appending: "/models")
        case .anthropic: url = try Self.url(settings.baseURL, appending: "/models", query: [URLQueryItem(name: "limit", value: "1000")])
        case .gemini: url = try Self.url(settings.baseURL, appending: "/models", query: [URLQueryItem(name: "pageSize", value: "1000")])
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        Self.authorize(&request, format: format, apiKey: apiKey)
        let data = try await send(request, format: format)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Self.unreadable }
        var ids: [String]
        switch format {
        case .openAI, .anthropic:
            ids = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .gemini:
            ids = (object["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true }
                .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
        }
        let notChat = #"(embed|whisper|tts|dall-e|davinci|babbage|moderation|image|audio|realtime|transcribe|speech|rerank|sora|veo|imagen|aqa)"#
        ids = ids.filter { $0.range(of: notChat, options: [.regularExpression, .caseInsensitive]) == nil }
        guard !ids.isEmpty else { throw AIFailure.invalidResponse("AI 服务没有返回可用的对话模型。") }
        return Array(Set(ids)).sorted().prefix(500).map { $0 }
    }

    /// Instructions for every Veer client; see `SystemPrompt`.
    public static func systemPrompt(config: String) -> String {
        SystemPrompt.build(config: config)
    }
}
