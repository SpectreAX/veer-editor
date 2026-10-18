import Foundation
import Testing
@testable import VeerCore

enum RegionalFixture {
    static let yaml = """
    proxies:
      - {name: "🇭🇰 香港 01", type: ss, server: hk.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: "🇲🇴 澳门 01", type: ss, server: mo.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: "🇯🇵 东京 01", type: ss, server: jp.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: "🇹🇼 台北 01", type: ss, server: tw.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: "Relay X", type: ss, server: x.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 🚀 Proxy, type: select, proxies: [香港自动, 澳门节点, 日本节点, 台湾自动, "Relay X"]}
      - {name: 香港自动, type: url-test, url: 'https://www.gstatic.com/generate_204', interval: 300, proxies: ["🇭🇰 香港 01"]}
      - {name: 澳门节点, type: select, proxies: ["🇲🇴 澳门 01"]}
      - {name: 日本节点, type: select, proxies: ["🇯🇵 东京 01"]}
      - {name: 台湾自动, type: url-test, url: 'https://www.gstatic.com/generate_204', interval: 300, proxies: ["🇹🇼 台北 01"]}
    rules:
      - MATCH,🚀 Proxy
    """
    static func document() throws -> ConfigDocument { try ConfigDocument.parse(yaml) }
    static func regions(_ doc: ConfigDocument) -> [String: Region] { Session(title: "", source: .pasted, text: yaml).regions(for: doc.targets) }
}

struct ExclusionTests {
    @Test func macauIsARegionAndGangAoMeansBoth() throws {
        #expect(Region.infer(from: "🇲🇴 澳门 01") == .mo && Region.infer(from: "澳门节点") == .mo)
        let asked = Region.allCases.filter { $0.instructionPattern.map("排除港澳节点".matches) ?? false }
        #expect(Set(asked) == [.hk, .mo])
    }

    @Test func bothReportedInstructionsWorkOffline() throws {
        let doc = try RegionalFixture.document()
        let regions = RegionalFixture.regions(doc)
        for prompt in ["AI服务排除港澳节点", "所有国外AI服务，策略组排除所有港澳节点"] {
            guard case .plan(let plan) = try LocalIntentParser.parse(prompt, targets: doc.targets, regions: regions) else {
                Issue.record("expected plan for \(prompt)"); continue
            }
            guard case .group(let group) = plan.operations.first else { Issue.record("expected group"); continue }
            #expect(group.name == "国外 AI 服务" && Set(group.excludeRegions) == [.hk, .mo] && group.regions.isEmpty)
            #expect(plan.operations.last == .ruleSet(.catalog(source: "metacubex-geosite", name: "category-ai-!cn"), targetId: "new-1"))
            let result = try PlanApplier.apply(plan, to: doc, regions: regions)
            // Regional groups outside HK/MO, in region order; the unknown-region node is left out.
            #expect(result.items.first?.group?.members == ["日本节点", "台湾自动"])
            #expect(result.items.first?.group?.excluded == ["香港", "澳门"])
            #expect(try ConfigDocument.parse(result.candidate).rules.first == "RULE-SET,category-ai-!cn,国外 AI 服务")
        }
    }

    @Test func plainNegationStillExplains() throws {
        let doc = try RegionalFixture.document()
        #expect(throws: EditorError.self) { try LocalIntentParser.parse("Netflix 不要走 Relay X", targets: doc.targets, regions: RegionalFixture.regions(doc)) }
    }
}

struct UnderstandingAndRepairTests {
    @Test func decodesUnderstandingAndProseWrappedJSON() throws {
        let decoded = try EditPlan.decodeReplyWithUnderstanding("好的，计划如下：\n{\"understanding\":\"AI 服务排除港澳\",\"schemaVersion\":1,\"operations\":[{\"kind\":\"remove_rule\",\"matchType\":\"DOMAIN\",\"match\":\"a.com\"}]}\n以上。")
        #expect(decoded.understanding == "AI 服务排除港澳")
        let ask = try EditPlan.decodeReplyWithUnderstanding(#"{"understanding":"缺少出口","clarification":"走哪里？"}"#)
        #expect(ask.understanding == "缺少出口")
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"understanding":"x","clarification":"y","operations":[]}"#) }
    }

    @Test func deepThinkingUsesTheReasoningModel() throws {
        var settings = AISettings(preset: .deepSeek)
        #expect(settings.effectiveReasoningModel == "deepseek-reasoner")
        let request = try AIClient().makeRequest(settings: settings, apiKey: "k", system: "s", history: [], prompt: "p", deepThinking: true)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-reasoner" && body["response_format"] == nil && body["temperature"] == nil)
        #expect(request.timeoutInterval == 180)
        settings.reasoningModel = "my-thinker"
        #expect(settings.effectiveReasoningModel == "my-thinker")
        // Old saved settings (no reasoningModel key) still decode.
        let old = try JSONDecoder().decode(AISettings.self, from: Data(#"{"preset":"openAI","baseURL":"https://api.openai.com/v1","model":"gpt-4.1-mini"}"#.utf8))
        #expect(old.effectiveReasoningModel == "o4-mini")
    }

    final class Scripted: AITransport, @unchecked Sendable {
        let replies: [String]
        var requests: [[String: Any]] = []
        private let lock = NSLock()
        init(_ replies: [String]) { self.replies = replies }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let index: Int = lock.withLock {
                requests.append((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:])
                return requests.count - 1
            }
            let message: [String: Any] = ["content": replies[min(index, replies.count - 1)], "reasoning_content": "先找服务，再找出口。"]
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": message]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    struct Pass: ConfigValidating { func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }; var versionDescription: String? { nil } }
    struct Verified: RuleSetVerifying { func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) } }

    final class Events: @unchecked Sendable {
        var items: [String] = []
        private let lock = NSLock()
        func add(_ value: String) { lock.withLock { items.append(value) } }
    }

    @Test func unusableAnswersAreSentBackOnce() async throws {
        let doc = try RegionalFixture.document()
        let bad = #"{"understanding":"AI 服务排除港澳","schemaVersion":1,"operations":[{"kind":"rule_set","source":"metacubex-geosite","name":"category-ai-!cn","targetId":"target-99"}]}"#
        let good = #"{"understanding":"国外 AI 服务排除港澳","schemaVersion":1,"operations":[{"kind":"group","id":"new-1","name":"AI 服务","type":"select","excludeRegions":["HK","MO"]},{"kind":"rule_set","source":"metacubex-geosite","name":"category-ai-!cn","targetId":"new-1"}]}"#
        let transport = Scripted([bad, good])
        let engine = EditorEngine(ai: AIClient(transport: transport), validator: Pass(), verifier: Verified())
        let events = Events()
        var request = EditorEngine.Request(prompt: "所有国外AI服务，策略组排除所有港澳节点", draft: doc, regions: RegionalFixture.regions(doc), useAI: true,
                                           settings: AISettings(), apiKey: "k")
        request.deepThinking = true
        let output = try await engine.run(request) { event in
            switch event {
            case .retrying(let problem): events.add("retry:\(problem)")
            case .understanding(let text): events.add("understanding:\(text)")
            case .reasoning(let text): events.add("reasoning:\(text)")
            default: break
            }
        }
        guard case .proposal(_, let items, _, _) = output else { Issue.record("expected proposal"); return }
        #expect(items.first?.group?.members == ["日本节点", "台湾自动"])
        #expect(events.items.contains { $0.hasPrefix("retry:") && $0.contains("不存在的出口") })
        #expect(events.items.contains("understanding:国外 AI 服务排除港澳"))
        #expect(events.items.contains("reasoning:先找服务，再找出口。"))
        #expect(transport.requests.count == 2)
        let followUp = (transport.requests[1]["messages"] as? [[String: String]])?.last?["content"] ?? ""
        #expect(followUp.contains("无法使用") && followUp.contains("不存在的出口"))
    }

    @Test func givesUpAfterOneRepair() async throws {
        let doc = try RegionalFixture.document()
        let engine = EditorEngine(ai: AIClient(transport: Scripted(["not json"])), validator: Pass(), verifier: Verified())
        await #expect(throws: EditorError.self) {
            _ = try await engine.run(.init(prompt: "x", draft: doc, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")) { _ in }
        }
    }
}
