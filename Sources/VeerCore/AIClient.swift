import Foundation

public struct AISettings: Sendable, Codable, Equatable {
    public enum Preset: String, Sendable, Codable, CaseIterable, Identifiable {
        case openAI, deepSeek, openRouter, ollama, custom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .openAI: "OpenAI"
            case .deepSeek: "DeepSeek"
            case .openRouter: "OpenRouter"
            case .ollama: "Ollama（本机）"
            case .custom: "自定义（OpenAI 兼容）"
            }
        }
        public var baseURL: String {
            switch self {
            case .openAI: "https://api.openai.com/v1"
            case .deepSeek: "https://api.deepseek.com/v1"
            case .openRouter: "https://openrouter.ai/api/v1"
            case .ollama: "http://127.0.0.1:11434/v1"
            case .custom: ""
            }
        }
        public var suggestedModel: String {
            switch self {
            case .openAI: "gpt-4.1-mini"
            case .deepSeek: "deepseek-chat"
            case .openRouter: "openai/gpt-4.1-mini"
            case .ollama: "qwen2.5:7b"
            case .custom: ""
            }
        }
        public var needsKey: Bool { self != .ollama }
    }

    public var preset: Preset
    public var baseURL: String
    public var model: String

    public init(preset: Preset = .deepSeek, baseURL: String? = nil, model: String? = nil) {
        self.preset = preset
        self.baseURL = baseURL ?? preset.baseURL
        self.model = model ?? preset.suggestedModel
    }
}

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
    case invalidResponse(String)
    case cancelled

    public var message: String {
        switch self {
        case .missingKey: "还没有设置 AI 服务的 API Key。"
        case .invalidEndpoint(let reason): reason
        case .network: "无法连接 AI 服务，请检查网络与服务地址。"
        case .timeout: "AI 服务 60 秒内没有响应。"
        case .unauthorized(let code): "AI 服务拒绝了请求（HTTP \(code)），请检查 API Key 与模型权限。"
        case .rateLimited: "AI 服务限流或额度不足（HTTP 429），请稍后重试。"
        case .server(let code): "AI 服务暂时出错（HTTP \(code)），可以重试。"
        case .http(let code): "AI 服务返回 HTTP \(code)，请检查地址和模型名称。"
        case .invalidResponse(let reason): reason
        case .cancelled: "已停止。"
        }
    }

    public var opensSettings: Bool {
        switch self {
        case .missingKey, .invalidEndpoint, .unauthorized, .http: true
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
    /// The full system instructions sent with the request (anonymous exits only).
    public var system: String?

    public init(model: String, exits: [String], history: [String], instruction: String, system: String? = nil) {
        self.model = model
        self.exits = exits
        self.history = history
        self.instruction = instruction
        self.system = system
    }

    public var readable: String {
        var text = "模型：\(model)\n\n出口表：\n" + exits.map { "· \($0)" }.joined(separator: "\n")
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

public struct AIClient: Sendable {
    let transport: AITransport
    public init(transport: AITransport = URLSessionTransport()) { self.transport = transport }

    public static func endpoint(for baseURL: String) throws -> URL {
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
        components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression) + "/chat/completions"
        return components.url!
    }

    public func makeRequest(settings: AISettings, apiKey: String?, system: String, history: [(role: String, content: String)], prompt: String) throws -> URLRequest {
        if settings.preset.needsKey && (apiKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty { throw AIFailure.missingKey }
        guard !settings.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw AIFailure.invalidEndpoint("请填写模型名称。") }
        var request = URLRequest(url: try Self.endpoint(for: settings.baseURL), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += history.map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = [
            "model": settings.model, "temperature": 0, "stream": false,
            "response_format": ["type": "json_object"], "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Sends one request and returns the assistant message content.
    public func complete(_ request: URLRequest) async throws -> String {
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
        switch response.statusCode {
        case 200..<300: break
        case 300..<400: throw AIFailure.invalidResponse("AI 服务返回了重定向，Veer 不会跟随。请检查服务地址。")
        case 401, 403: throw AIFailure.unauthorized(response.statusCode)
        case 429: throw AIFailure.rateLimited
        case 500...: throw AIFailure.server(response.statusCode)
        default: throw AIFailure.http(response.statusCode)
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (reply["choices"] as? [[String: Any]])?.first else {
            throw AIFailure.invalidResponse("AI 服务返回了无法读取的响应，请重试。")
        }
        if let finish = choice["finish_reason"] as? String, finish != "stop" {
            throw AIFailure.invalidResponse("AI 的回答没有完整结束，请缩短指令或检查模型设置后重试。")
        }
        guard let content = (choice["message"] as? [String: Any])?["content"] as? String, !content.isEmpty, content.count <= 100_000 else {
            throw AIFailure.invalidResponse("AI 返回的内容为空或超过长度限制。")
        }
        return content
    }

    /// Minimal request with no configuration data: confirms key, model and JSON mode work.
    public func testConnection(settings: AISettings, apiKey: String?) async throws {
        let request = try makeRequest(settings: settings, apiKey: apiKey, system: "Reply with the JSON object {\"ok\":true} and nothing else.", history: [], prompt: "ping")
        let content = try await complete(request)
        guard content.contains("ok") else { throw AIFailure.invalidResponse("AI 服务可以连接，但没有按 JSON 格式回答。请换一个支持 JSON 输出的模型。") }
    }

    /// Instructions for every Veer client; see `SystemPrompt`.
    public static func systemPrompt(exits: [AnonymousContext.Exit]) -> String {
        SystemPrompt.build(exits: exits)
    }
}
