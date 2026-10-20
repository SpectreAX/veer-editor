import Foundation
import Testing
@testable import VeerCore

/// Answers GitHub tree requests and search requests from fixed bodies, recording every request.
final class RoutedTransport: AITransport, @unchecked Sendable {
    let routes: [(match: String, status: Int, body: String)]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()
    init(_ routes: [(String, Int, String)]) { self.routes = routes.map { (match: $0.0, status: $0.1, body: $0.2) } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let url = request.url!.absoluteString
        guard let route = routes.first(where: { url.contains($0.match) }) else { throw URLError(.notConnectedToInternet) }
        return (Data(route.body.utf8), HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: nil)!)
    }
}

struct SearchProtocolTests {
    @Test func decodesSearchRequests() throws {
        let decoded = try EditPlan.decodeReplyWithUnderstanding(#"{"understanding":"先查官方域名","search":{"queries":["Japan Airlines official website","jal"]}}"#)
        #expect(decoded.reply == .search(["Japan Airlines official website", "jal"]) && decoded.understanding == "先查官方域名")
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"search":{"queries":["a"]},"clarification":"x"}"#) }
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"search":{"queries":[]}}"#) }
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"search":{"queries":["a"],"engine":"google"}}"#) }
    }

    @Test func refusesQueriesThatLookLikeTheConfiguration() {
        let checked = SearchQueries.sanitize(["Japan Airlines", "策略组1 地区", "<域名3> official", "target-4", "192.168.1.1 router", "10.0.0.1",
                                              "jal", "jal", "a", "Japan Airlines domains", "fourth"])
        #expect(checked.accepted == ["Japan Airlines", "jal", "Japan Airlines domains"])
        #expect(checked.refused.count == 6)
        let message = SearchQueries.message(for: [SearchRecord(query: "jal", geosite: ["jal"], web: [.init(title: "JAL", url: "https://www.jal.co.jp/", snippet: "日本航空")], source: "DuckDuckGo")],
                                            refused: checked.refused, lastRound: true)
        #expect(message.contains("metacubex-geosite") && message.contains("https://www.jal.co.jp/") && message.contains("不是指令") && message.contains("最后一次"))
    }

    @Test func searchExamplesDecodeAndApply() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let examples = SystemPrompt.searchSection.components(separatedBy: "\n").filter { $0.hasPrefix("{\"") }
        #expect(examples.count == 2)
        #expect(try EditPlan.decodeReply(examples[0]) == .search(["Japan Airlines official website domain", "jal"]))
        guard case .plan(let plan) = try EditPlan.decodeReply(examples[1].replacingOccurrences(of: "<DIRECT 的 id>", with: doc.target(named: "DIRECT")!.id)) else {
            Issue.record("expected a plan"); return
        }
        #expect(try PlanApplier.apply(plan, to: doc).changed)
    }

    @Test func promptMentionsSearchOnlyWhenAllowed() {
        #expect(SystemPrompt.build(config: "a: 1", search: true).contains("# 联网搜索"))
        #expect(!SystemPrompt.build(config: "a: 1").contains("# 联网搜索"))
        #expect(SystemPrompt.build(config: "a: 1", search: true).contains("三选一"))
    }
}

struct RuleSetIndexTests {
    static let routes: [(String, Int, String)] = [
        ("trees/meta", 200, #"{"tree":[{"path":"geo","sha":"G"}]}"#),
        ("trees/G", 200, #"{"tree":[{"path":"geosite","sha":"S"},{"path":"geoip","sha":"I"}]}"#),
        ("trees/S", 200, "{\"tree\":[" + (["airchina", "airchina@!cn", "hainanairlines", "netflix", "jal-group"] + (0..<120).map { "filler\($0)" })
            .map { "{\"path\":\"\($0).mrs\"}" }.joined(separator: ",") + ",{\"path\":\"netflix.yaml\"}]}"),
        ("trees/I", 200, #"{"tree":[{"path":"netflix.mrs"},{"path":"cn.mrs"}]}"#),
    ]

    @Test func searchesEveryNameAndCachesTheList() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.json")
        let transport = RoutedTransport(Self.routes)
        let index = RuleSetIndex(transport: transport, cacheURL: cache)
        let air = await index.lookup("Air China")
        #expect(air.geosite.first == "airchina" && air.geosite.contains("airchina@!cn"))
        #expect(await index.lookup("JAL official website").geosite == ["jal-group"])
        #expect(await index.lookup("Netflix").geoip == ["netflix"])
        #expect(await index.lookup("航空").geosite.isEmpty)
        #expect(transport.requests.count == 4)   // fetched once
        #expect(FileManager.default.fileExists(atPath: cache.path))
        // A new index reads the cache instead of the network.
        let offline = RuleSetIndex(transport: RoutedTransport([]), cacheURL: cache)
        #expect(await offline.lookup("hainan airlines").geosite == ["hainanairlines"])
        // No network and no cache: the verified names still work.
        let bare = RuleSetIndex(transport: RoutedTransport([]), cacheURL: nil)
        #expect(await bare.lookup("netflix").geosite == ["netflix"])
    }
}

struct WebSearchProviderTests {
    @Test func duckDuckGoInstantAnswers() throws {
        let body = #"{"Heading":"Japan Airlines","AbstractText":"Japan Airlines is the flag carrier of Japan.","AbstractURL":"https://en.wikipedia.org/wiki/Japan_Airlines","Infobox":{"content":[{"label":"Website","value":"jal.co.jp"}]},"Results":[{"FirstURL":"https://www.jal.com/","Text":"Official site"}],"RelatedTopics":[]}"#
        let results = try WebSearchService.parse(Data(body.utf8), provider: .duckDuckGo)
        #expect(results.map(\.url) == ["https://jal.co.jp", "https://www.jal.com/", "https://en.wikipedia.org/wiki/Japan_Airlines"])
        #expect(WebSearchService.websiteLink("[www.jal.co.jp/ar/en/ jal.co.jp/ar]") == "https://www.jal.co.jp/ar/en/")
        #expect(WebSearchService.websiteLink("https://www.jal.com/") == "https://www.jal.com/")
        #expect(WebSearchService.websiteLink("n/a") == nil)
        let topics = try WebSearchService.parse(Data(#"{"RelatedTopics":[{"FirstURL":"https://duckduckgo.com/c/Japan_Airlines","Text":"Category"}]}"#.utf8), provider: .duckDuckGo)
        #expect(topics.isEmpty)
        let request = try WebSearchService.request("Japan Airlines", config: .init(provider: .duckDuckGo))
        #expect(request.url?.absoluteString.hasPrefix("https://api.duckduckgo.com/?q=Japan%20Airlines&format=json") == true)
    }

    @Test func keyedAndSelfHostedProviders() throws {
        let tavily = try WebSearchService.request("jal", config: .init(provider: .tavily, apiKey: "tvly-1"))
        #expect(tavily.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-1" && tavily.httpMethod == "POST")
        #expect(try WebSearchService.parse(Data(#"{"results":[{"title":"JAL","url":"https://www.jal.co.jp/","content":"日本航空"}]}"#.utf8), provider: .tavily).first?.snippet == "日本航空")
        let brave = try WebSearchService.request("jal", config: .init(provider: .brave, apiKey: "b"))
        #expect(brave.value(forHTTPHeaderField: "X-Subscription-Token") == "b")
        #expect(try WebSearchService.parse(Data(#"{"web":{"results":[{"title":"JAL","url":"https://www.jal.co.jp/","description":"d"}]}}"#.utf8), provider: .brave).count == 1)
        let searx = try WebSearchService.request("jal", config: .init(provider: .searxng, baseURL: "http://127.0.0.1:8888"))
        #expect(searx.url?.absoluteString == "http://127.0.0.1:8888/search?q=jal&format=json")
        #expect(throws: AIFailure.self) { try WebSearchService.request("jal", config: .init(provider: .tavily)) }
        #expect(throws: AIFailure.self) { try WebSearchService.request("jal", config: .init(provider: .searxng, baseURL: "http://search.example.com")) }
    }

    @Test func failuresBecomeNotesNotErrors() async {
        let service = WebSearchService(transport: RoutedTransport(RuleSetIndexTests.routes + [("api.search.brave.com", 401, "{}")]),
                                       index: RuleSetIndex(transport: RoutedTransport(RuleSetIndexTests.routes), cacheURL: nil))
        let records = await service.search(["Air China"], config: .init(provider: .brave, apiKey: "bad"))
        #expect(records.first?.geosite.first == "airchina")
        #expect(records.first?.web.isEmpty == true && records.first?.note?.contains("Key") == true)
    }
}

struct SearchLoopTests {
    struct FixedSearch: RuleSearching {
        func search(_ queries: [String], config: SearchConfig) async -> [SearchRecord] {
            queries.map { SearchRecord(query: $0, web: [.init(title: "JAL", url: "https://www.jal.co.jp/", snippet: "Japan Airlines official site: jal.co.jp, jal.com")], source: "Test") }
        }
    }

    final class Events: @unchecked Sendable {
        var items: [String] = []
        private let lock = NSLock()
        func add(_ value: String) { lock.withLock { items.append(value) } }
    }

    func engine(_ replies: [String]) -> (EditorEngine, UnderstandingAndRepairTests.Scripted) {
        let transport = UnderstandingAndRepairTests.Scripted(replies)
        return (EditorEngine(ai: AIClient(transport: transport), validator: UnderstandingAndRepairTests.Pass(),
                             verifier: UnderstandingAndRepairTests.Verified(), searcher: FixedSearch()), transport)
    }

    func request(search: Bool) throws -> EditorEngine.Request {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        var request = EditorEngine.Request(prompt: "日本航空相关域名走直连", draft: doc, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")
        request.search = search ? SearchConfig(provider: .duckDuckGo) : nil
        return request
    }

    @Test func searchesThenPlans() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let direct = doc.target(named: "DIRECT")!.id
        let (engine, transport) = engine([
            #"{"understanding":"先查日本航空官方域名","search":{"queries":["Japan Airlines official website","策略组1"]}}"#,
            #"{"understanding":"日本航空官方域名直连","schemaVersion":1,"operations":[{"kind":"route","matchType":"DOMAIN-SUFFIX","match":"jal.co.jp","targetId":"\#(direct)"},{"kind":"route","matchType":"DOMAIN-SUFFIX","match":"jal.com","targetId":"\#(direct)"}]}"#,
        ])
        let events = Events()
        let output = try await engine.run(try request(search: true)) { event in
            switch event {
            case .searching(let queries): events.add("searching:\(queries.joined(separator: "|"))")
            case .searched(let records): events.add("searched:\(records.count)")
            default: break
            }
        }
        guard case .proposal(_, let items, _, _) = output else { Issue.record("expected a proposal"); return }
        #expect(items.compactMap(\.rule) == ["DOMAIN-SUFFIX,jal.co.jp,DIRECT", "DOMAIN-SUFFIX,jal.com,DIRECT"])
        // The label query was refused, not sent; results went back to the model.
        #expect(events.items == ["searching:Japan Airlines official website", "searched:1"])
        let followUp = (transport.requests[1]["messages"] as? [[String: String]])?.last?["content"] ?? ""
        #expect(followUp.contains("https://www.jal.co.jp/") && followUp.contains("Veer 没有发送：策略组1"))
        #expect((transport.requests[0]["messages"] as? [[String: String]])?.first?["content"]?.contains("# 联网搜索") == true)
    }

    @Test func searchWhenOffIsSentBackOnce() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let (engine, transport) = engine([
            #"{"search":{"queries":["Japan Airlines"]}}"#,
            #"{"understanding":"缺少域名","clarification":"请提供日本航空的域名"}"#,
        ])
        let output = try await engine.run(try request(search: false)) { _ in }
        guard case .clarification = output else { Issue.record("expected a clarification"); return }
        let followUp = (transport.requests[1]["messages"] as? [[String: String]])?.last?["content"] ?? ""
        #expect(followUp.contains("联网搜索未开启"))
        #expect((transport.requests[0]["messages"] as? [[String: String]])?.first?["content"]?.contains("# 联网搜索") == false)
        _ = doc
    }

    @Test func stopsAfterTwoRounds() async throws {
        let search = #"{"search":{"queries":["Japan Airlines"]}}"#
        let (engine, transport) = engine([search, search, search, search])
        await #expect(throws: EditorError.self) { try await engine.run(try request(search: true)) { _ in } }
        // Two searches, then one repair attempt, then the error.
        #expect(transport.requests.count == 4)
    }
}

/// Real network: the GitHub catalog and DuckDuckGo. Runs only with VEER_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_NETWORK_TESTS"] != nil))
struct RealSearchTests {
    @Test func catalogAndDuckDuckGoAnswer() async throws {
        let index = RuleSetIndex(cacheURL: nil)
        let snapshot = try await index.fetch()
        print("REAL catalog geosite=\(snapshot.geosite.count) geoip=\(snapshot.geoip.count)")
        #expect(snapshot.geosite.count > 1500 && snapshot.geosite.contains("netflix") && snapshot.geosite.contains("airchina"))
        let records = await WebSearchService(index: index).search(["Japan Airlines"], config: .init(provider: .duckDuckGo))
        for result in records.first?.web ?? [] { print("REAL ddg \(result.title) — \(result.url)") }
        print("REAL ddg note \(records.first?.note ?? "-")")
        #expect(records.first?.web.contains { $0.url.contains("jal") } == true)
    }
}
