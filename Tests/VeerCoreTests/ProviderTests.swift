import Foundation
import Testing
@testable import VeerCore

/// Replies with one fixed body and records every request.
final class Recording: AITransport, @unchecked Sendable {
    let status: Int
    let body: String
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()
    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func json(_ request: AIRequest) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: request.urlRequest.httpBody!) as? [String: Any])
}

struct ProviderCatalogTests {
    @Test func everyServiceHasAnAddressAndADefaultModel() {
        for provider in AIProvider.allCases where provider != .custom {
            #expect(!provider.baseURL.isEmpty && !provider.defaultModel.isEmpty, "\(provider)")
            #expect((try? AIClient.validatedBase(provider.baseURL)) != nil, "\(provider)")
            for entry in provider.catalog { #expect(provider.thinkingStyle(for: entry.model) == entry.style) }
        }
    }

    @Test func thinkingStrengthFollowsTheModel() {
        var settings = AISettings(provider: .deepSeek)
        #expect(settings.models == ["deepseek-flash", "deepseek-v4-pro"])
        #expect(settings.thinkingStyle.levels == [.off, .low, .high, .max] && !settings.thinks)
        settings.thinkingLevel = .medium
        #expect(settings.effectiveLevel == .high && settings.modelLabel == "deepseek-flash · 深度思考 · 高")
        settings.thinkingLevel = .max
        settings.select(model: "deepseek-v4-pro")
        #expect(settings.modelLabel == "deepseek-v4-pro · 深度思考 · 最高")
        // A reasoning model always thinks; going back keeps the user's choice.
        var openAI = AISettings(provider: .openAI)
        #expect(openAI.thinkingStyle.levels == [.off] && openAI.modelLabel == "gpt-4.1-mini")
        openAI.select(model: "o4-mini")
        #expect(openAI.thinks && !openAI.thinkingStyle.adjustable && openAI.modelLabel == "o4-mini · 深度思考")
        openAI.select(model: "gpt-5-mini")
        #expect(!openAI.thinks)
        var glm = AISettings(provider: .zhipu, thinkingLevel: .low)
        #expect(glm.effectiveLevel == .high && glm.thinkingStyle.title(of: .high) == "开启")
        glm.thinkingLevel = .off
        #expect(!glm.thinks)
    }

    @Test func retiredDeepSeekModelsAreReplaced() throws {
        let chat = try JSONDecoder().decode(AISettings.self, from: Data(#"{"preset":"deepSeek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat","thinking":false,"fetchedModels":["deepseek-chat","deepseek-reasoner","deepseek-flash"]}"#.utf8))
        #expect(chat.model == "deepseek-flash" && !chat.thinks && chat.fetchedModels == ["deepseek-flash"])
        let reasoner = try JSONDecoder().decode(AISettings.self, from: Data(#"{"preset":"deepSeek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-reasoner","thinking":true}"#.utf8))
        #expect(reasoner.model == "deepseek-flash" && reasoner.effectiveLevel == .high)
        var typed = AISettings(provider: .deepSeek)
        typed.select(model: "deepseek-reasoner")
        #expect(typed.model == "deepseek-flash" && typed.thinks)
        #expect(AISettings(provider: .deepSeek, model: "deepseek-chat").model == "deepseek-flash")
    }

    @Test func infersThinkingForFetchedModels() {
        #expect(AIProvider.openRouter.thinkingStyle(for: "deepseek/deepseek-r1-0528") == .intrinsic)
        #expect(AIProvider.openAI.thinkingStyle(for: "o3") == .intrinsic)
        #expect(AIProvider.openAI.thinkingStyle(for: "gpt-5") == .openAIEffort)
        #expect(AIProvider.openAI.thinkingStyle(for: "gpt-5-chat-latest") == .none)
        #expect(AIProvider.gemini.thinkingStyle(for: "gemini-2.5-pro-preview") == .intrinsic)
        #expect(AIProvider.gemini.thinkingStyle(for: "gemini-2.0-flash") == .none)
        #expect(AIProvider.anthropic.thinkingStyle(for: "claude-3-5-haiku-latest") == .none)
        #expect(AIProvider.anthropic.thinkingStyle(for: "claude-sonnet-4-5") == .anthropic)
        #expect(AIProvider.siliconFlow.thinkingStyle(for: "Qwen/QwQ-32B") == .intrinsic)
        #expect(AIProvider.zhipu.thinkingStyle(for: "glm-4.5") == .zhipu)
        #expect(AIProvider.deepSeek.thinkingStyle(for: "deepseek-chat-r10") == .deepSeek)
        #expect(AIProvider.deepSeek.thinkingStyle(for: "deepseek-v4-pro") == .deepSeek)
    }

    @Test func currentModelStaysInTheMenu() {
        var settings = AISettings(provider: .openAI)
        settings.fetchedModels = ["gpt-4.1-nano", "gpt-4.1"]
        settings.select(model: "ft:gpt-4.1:me")
        let ids = settings.models
        #expect(ids.contains("gpt-4.1-nano") && ids.last == "ft:gpt-4.1:me" && ids.filter { $0 == "gpt-4.1" }.count == 1)
        #expect(!settings.models(includingFetched: false).contains("gpt-4.1-nano"))
    }

    @Test func migratesTheOldThinkingToggle() throws {
        let old = Data(#"{"preset":"deepSeek","baseURL":"https://api.deepseek.com/v1","model":"deepseek-chat"}"#.utf8)
        var on = try JSONDecoder().decode(AISettings.self, from: old)
        on.migrateLegacy(deepThinking: true)
        #expect(on.model == "deepseek-flash" && on.effectiveLevel == .high)
        var off = try JSONDecoder().decode(AISettings.self, from: old)
        off.migrateLegacy(deepThinking: false)
        #expect(off.model == "deepseek-flash" && !off.thinks)
        var custom = try JSONDecoder().decode(AISettings.self, from: Data(#"{"preset":"openAI","baseURL":"https://api.openai.com/v1","model":"gpt-4.1","reasoningModel":"o3"}"#.utf8))
        custom.migrateLegacy(deepThinking: true)
        #expect(custom.model == "o3" && custom.thinks)
        // New settings round-trip and never migrate again.
        var again = try JSONDecoder().decode(AISettings.self, from: try JSONEncoder().encode(on))
        again.migrateLegacy(deepThinking: false)
        #expect(again == on)
        let encoded = String(decoding: try JSONEncoder().encode(on), as: UTF8.self)
        #expect(encoded.contains("\"preset\":\"deepSeek\"") && !encoded.contains("reasoningModel"))
    }
}

struct ProviderRequestTests {
    @Test func claudeUsesTheMessagesAPI() async throws {
        var settings = AISettings(provider: .anthropic)
        let history: [(role: String, content: String)] = [("assistant", "孤立的回答"), ("user", "上一轮"), ("assistant", "好的")]
        let plain = try AIClient().makeRequest(settings: settings, apiKey: "sk-ant", system: "SYS", history: history, prompt: "Netflix 走日本")
        #expect(plain.urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(plain.urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(plain.urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(plain.urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        var body = try json(plain)
        #expect(body["system"] as? String == "SYS" && body["temperature"] as? Int == 0 && body["thinking"] == nil)
        let roles = (body["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }
        #expect(roles == ["user", "assistant", "user"])

        settings.thinkingLevel = .medium
        let thinking = try AIClient().makeRequest(settings: settings, apiKey: "sk-ant", system: "SYS", history: [], prompt: "p")
        body = try json(thinking)
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 8_000)
        #expect(body["temperature"] == nil && (body["max_tokens"] as? Int ?? 0) > 8_000)
        #expect(thinking.urlRequest.timeoutInterval == 180)

        let reply = #"{"content":[{"type":"thinking","thinking":"先找服务"},{"type":"text","text":"{\"clarification\":\"走哪里？\"}"}],"stop_reason":"end_turn"}"#
        let answer = try await AIClient(transport: Recording(body: reply)).completeWithReasoning(thinking)
        #expect(answer.content == #"{"clarification":"走哪里？"}"# && answer.reasoning == "先找服务")
        await #expect(throws: AIClient.incomplete) {
            try await AIClient(transport: Recording(body: #"{"content":[{"type":"text","text":"{"}],"stop_reason":"max_tokens"}"#)).complete(plain)
        }
    }

    @Test func geminiUsesGenerateContent() async throws {
        var settings = AISettings(provider: .gemini)
        let plain = try AIClient().makeRequest(settings: settings, apiKey: "AIza", system: "SYS", history: [("user", "a"), ("assistant", "b")], prompt: "c")
        #expect(plain.urlRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(plain.urlRequest.value(forHTTPHeaderField: "x-goog-api-key") == "AIza")
        var body = try json(plain)
        let generation = try #require(body["generationConfig"] as? [String: Any])
        #expect(generation["responseMimeType"] as? String == "application/json")
        #expect((generation["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int == 0)
        #expect((body["contents"] as? [[String: Any]])?.map { $0["role"] as? String } == ["user", "model", "user"])

        settings.thinkingLevel = .high
        body = try json(try AIClient().makeRequest(settings: settings, apiKey: "AIza", system: "SYS", history: [], prompt: "c"))
        let thinkingConfig = (body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
        #expect(thinkingConfig?["thinkingBudget"] as? Int == -1 && thinkingConfig?["includeThoughts"] as? Bool == true)

        let reply = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"想一想","thought":true},{"text":"{\"clarification\":\"哪个？\"}"}]}}]}"#
        let answer = try await AIClient(transport: Recording(body: reply)).completeWithReasoning(plain)
        #expect(answer.content == #"{"clarification":"哪个？"}"# && answer.reasoning == "想一想")
        await #expect(throws: AIFailure.unauthorized(400)) {
            try await AIClient(transport: Recording(status: 400, body: #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key."}}"#)).complete(plain)
        }
        await #expect(throws: AIFailure.invalidResponse("AI 服务拒绝回答（SAFETY），请换一种说法。")) {
            try await AIClient(transport: Recording(body: #"{"candidates":[{"finishReason":"SAFETY"}]}"#)).complete(plain)
        }
    }

    @Test func openAICompatibleThinkingParameters() throws {
        var gpt5 = AISettings(provider: .openAI, model: "gpt-5-mini")
        var body = try json(try AIClient().makeRequest(settings: gpt5, apiKey: "k", system: "s", history: [], prompt: "p"))
        #expect(body["reasoning_effort"] as? String == "minimal" && body["temperature"] == nil && body["response_format"] != nil)
        gpt5.thinkingLevel = .medium
        body = try json(try AIClient().makeRequest(settings: gpt5, apiKey: "k", system: "s", history: [], prompt: "p"))
        #expect(body["reasoning_effort"] as? String == "medium")

        var glm = AISettings(provider: .zhipu)
        let request = try AIClient().makeRequest(settings: glm, apiKey: "k", system: "s", history: [], prompt: "p")
        #expect(request.urlRequest.url?.absoluteString == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect((try json(request)["thinking"] as? [String: String])?["type"] == "disabled")
        glm.thinkingLevel = .high
        body = try json(try AIClient().makeRequest(settings: glm, apiKey: "k", system: "s", history: [], prompt: "p"))
        #expect((body["thinking"] as? [String: String])?["type"] == "enabled" && body["response_format"] == nil)

        // DeepSeek V4 thinks by default, so "off" must be sent explicitly.
        var deepSeek = AISettings(provider: .deepSeek)
        body = try json(try AIClient().makeRequest(settings: deepSeek, apiKey: "k", system: "s", history: [], prompt: "p"))
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled" && body["reasoning_effort"] == nil)
        #expect(body["temperature"] as? Int == 0 && body["response_format"] != nil)
        deepSeek.select(model: "deepseek-v4-pro")
        deepSeek.thinkingLevel = .max
        let maxed = try AIClient().makeRequest(settings: deepSeek, apiKey: "k", system: "s", history: [], prompt: "p")
        body = try json(maxed)
        #expect((body["thinking"] as? [String: String])?["type"] == "enabled" && body["reasoning_effort"] as? String == "max")
        #expect(body["temperature"] == nil && body["response_format"] == nil && maxed.urlRequest.timeoutInterval == 300)

        let chat = try json(try AIClient().makeRequest(settings: AISettings(provider: .qwen), apiKey: "k", system: "s", history: [], prompt: "p"))
        #expect(chat["temperature"] as? Int == 0 && chat["thinking"] == nil)
    }

    @Test func separatesThinkTagsAndReportsServiceErrors() async throws {
        let request = try AIClient().makeRequest(settings: AISettings(provider: .ollama, model: "deepseek-r1:8b"), apiKey: nil, system: "s", history: [], prompt: "p")
        #expect(request.urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let reply = #"{"choices":[{"finish_reason":"stop","message":{"content":"<think>用户要 {走日本}</think>\n{\"clarification\":\"哪个？\"}"}}]}"#
        let answer = try await AIClient(transport: Recording(body: reply)).completeWithReasoning(request)
        #expect(answer.content == #"{"clarification":"哪个？"}"# && answer.reasoning == "用户要 {走日本}")
        let failure = AIFailure.rejected(404, "The model `gpt-9` does not exist")
        await #expect(throws: failure) {
            try await AIClient(transport: Recording(status: 404, body: #"{"error":{"message":"The model `gpt-9` does not exist"}}"#)).complete(request)
        }
        #expect(failure.message.contains("gpt-9") && failure.opensSettings)
    }

    @Test func listsChatModels() async throws {
        let openAI = Recording(body: #"{"data":[{"id":"gpt-4.1"},{"id":"text-embedding-3-small"},{"id":"whisper-1"},{"id":"gpt-4.1"},{"id":"o3"}]}"#)
        let models = try await AIClient(transport: openAI).listModels(settings: AISettings(provider: .openAI), apiKey: "k")
        #expect(models == ["gpt-4.1", "o3"])
        #expect(openAI.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(openAI.requests.first?.httpBody == nil)

        let gemini = Recording(body: #"{"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}]}"#)
        #expect(try await AIClient(transport: gemini).listModels(settings: AISettings(provider: .gemini), apiKey: "k") == ["gemini-2.5-flash"])
        #expect(gemini.requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == "k")

        await #expect(throws: AIFailure.missingKey) { try await AIClient().listModels(settings: AISettings(provider: .anthropic), apiKey: nil) }
    }
}

struct FileKeyStoreTests {
    @Test func keysArePerServiceAndOnlyReadableByTheUser() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("api-keys.json")
        let store = FileKeyStore(url: url)
        #expect(store.read(for: "deepSeek") == nil)
        try store.save("sk-one", for: "deepSeek")
        try store.save("sk-two", for: "anthropic")
        #expect(store.read(for: "deepSeek") == "sk-one" && FileKeyStore(url: url).read(for: "anthropic") == "sk-two")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try store.save("sk-three", for: "deepSeek")
        #expect(store.read(for: "deepSeek") == "sk-three")
        store.delete(for: "deepSeek")
        store.delete(for: "anthropic")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
