import Foundation
import Testing
@testable import VeerCore
@testable import VeerEditorApp

struct PassValidator: ConfigValidating {
    func validate(_ yaml: String) async -> ValidationResult {
        try? await Task.sleep(for: .milliseconds(50))
        return .init(status: .passed, message: "ok")
    }
    var versionDescription: String? { "test" }
}

struct VerifiedAll: RuleSetVerifying {
    func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) }
}

@MainActor
struct StoreTests {
    func makeStore() -> EditorStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EditorStore(store: SessionStore(directory: directory), keyStore: MemoryKeyStore(),
                                engine: EditorEngine(validator: PassValidator(), verifier: VerifiedAll()),
                                defaults: MemoryDefaults(), persist: false)
        store.useAI = false
        store.loadSample()
        store.confirmExits()
        return store
    }

    func waitIdle(_ store: EditorStore) async {
        for _ in 0..<200 where store.isRunning || !store.revalidating.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func writeUndoRedoKeepsTurnStatusInStep() async throws {
        let store = makeStore()
        store.send("Netflix 走日本，ChatGPT 走美国")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        #expect(turn.proposal?.items.count == 2)
        #expect(store.canWrite(turn))

        store.write()
        #expect(store.current?.turns.last?.proposal?.status == .written)
        #expect(store.current?.hasUnexportedChanges == true)
        #expect(store.draft?.rules.prefix(2) == ["RULE-SET,netflix,日本出口", "RULE-SET,openai,美国出口"])

        store.undo()
        #expect(store.current?.draftText == SampleConfig.text)
        #expect(store.current?.turns.first?.proposal?.status == .undone)
        #expect(store.current?.turns.last?.isNote == true)

        store.redo()
        #expect(store.current?.turns.first?.proposal?.status == .written)
        #expect(store.draft?.rules.first == "RULE-SET,netflix,日本出口")
    }

    @Test func candidatesFromAnOlderDraftCannotBeWrittenUntilTheDraftMatchesAgain() async throws {
        let store = makeStore()
        store.send("YouTube 走香港")
        await waitIdle(store)
        store.send("example.org 直连")
        await waitIdle(store)
        let first = try #require(store.current?.turns.first), second = try #require(store.current?.turns.last)
        store.write(turnID: second.id)
        #expect(!store.canWrite(store.current!.turns.first!))
        #expect(first.proposal?.status == .pending)
        store.undo()
        #expect(store.canWrite(store.current!.turns.first!))
    }

    @Test func writingWaitsForRevalidationAndUsesTheAcceptedSubset() async throws {
        let store = makeStore()
        store.send("Netflix 走日本，ChatGPT 走美国")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        store.setAccepted(false, item: 1, turnID: turn.id)
        #expect(!store.canWrite(store.current!.turns.last!))
        store.write(turnID: turn.id)
        #expect(store.current?.turns.last?.proposal?.status == .pending)
        await waitIdle(store)
        store.write(turnID: turn.id)
        #expect(store.draft?.rules.first == "RULE-SET,netflix,日本出口")
        #expect(store.draft?.providers.map(\.key) == ["netflix"])
        #expect(store.draft?.rules.contains("DOMAIN-SUFFIX,openai.com,DIRECT") == true)
    }

    @Test func outOfScopeAndClarificationNeverChangeTheDraft() async {
        let store = makeStore()
        store.send("节点太卡了换一个")
        await waitIdle(store)
        store.send("YouTube 走代理")
        await waitIdle(store)
        #expect(store.current?.turns.map(\.outcome).contains(.outOfScope(LocalIntentParser.outOfScopeMessage)) == true)
        if case .clarify(_, let options) = store.current?.turns.last?.outcome { #expect(!options.isEmpty) } else { Issue.record("expected clarification") }
        #expect(store.current?.draftText == SampleConfig.text)
    }

    @Test func aiFailuresOfferRecoveryAndPayloadIsAnonymous() async throws {
        let store = makeStore()
        store.useAI = true
        store.sessionKey = "sk-test-secret"
        store.settings.baseURL = "http://example.com/v1"
        store.send("Netflix 走日本出口")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        guard case let .failure(message, opensSettings, canUseLocal) = turn.outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("HTTPS"))
        #expect(opensSettings && canUseLocal)
        let payload = try #require(turn.sentPayload).readable
        #expect(payload.contains("策略组1（日本）"))
        #expect(!payload.contains("日本出口") && !payload.contains("sk-test") && !payload.contains("password"))
    }

    @Test func settingsAreRepairedMigratedAndKeptPerService() throws {
        let defaults = MemoryDefaults()
        // What earlier snapshot runs left in the real preferences, plus the old thinking toggle.
        defaults.set(Data(#"{"preset":"deepSeek","baseURL":"https://127.0.0.1:9/v1","model":"deepseek-chat"}"#.utf8), forKey: "aiSettings")
        defaults.set(true, forKey: "deepThinking")
        let keys = MemoryKeyStore()
        try keys.save("sk-deepseek", for: "deepSeek")
        let store = EditorStore(store: SessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                                keyStore: keys, defaults: defaults, persist: false)
        #expect(store.settings.baseURL == "https://api.deepseek.com/v1")
        #expect(store.settings.modelLabel == "deepseek-flash · 深度思考 · 高")
        #expect(defaults.object(forKey: "deepThinking") == nil)
        #expect(store.keySaved && store.apiKey == "sk-deepseek")

        store.selectProvider(.anthropic)
        #expect(store.settings.model == "claude-sonnet-5-5" && !store.keySaved && store.apiKey == nil)
        store.sessionKey = "sk-ant-session"
        store.settings.select(model: "claude-haiku-5-5")
        store.settings.thinkingLevel = .low
        store.selectProvider(.deepSeek)
        #expect(store.apiKey == "sk-deepseek" && store.settings.model == "deepseek-flash")
        store.selectProvider(.anthropic)
        #expect(store.apiKey == "sk-ant-session" && store.settings.modelLabel == "claude-haiku-5-5 · 深度思考 · 低")
    }

    @Test func longSessionsOpenWithTheirNewestTurns() throws {
        let store = makeStore()
        var long = Session(title: "long", source: .sample, text: SampleConfig.text)
        long.turns = (0..<25).map { Turn(prompt: "\($0)", mode: .local, steps: [], outcome: .note("\($0)")) }
        let short = Session(title: "short", source: .sample, text: SampleConfig.text)
        store.sessions = [long, short]
        store.select(long.id)
        #expect(store.visibleTurnCount == EditorStore.turnPage)
        store.olderTurnPages += 1
        #expect(store.visibleTurnCount == 2 * EditorStore.turnPage)
        // New turns are always shown, on top of the window.
        long.turns.append(Turn(prompt: "new", mode: .local, steps: [], outcome: .note("new")))
        store.current = long
        #expect(store.visibleTurnCount == 2 * EditorStore.turnPage + 1)
        // Switching resets the window.
        store.select(short.id)
        store.select(long.id)
        #expect(store.visibleTurnCount == EditorStore.turnPage)
    }

    @Test func lookupResultsKnowWhatTheDraftUses() throws {
        let store = makeStore()
        let config = """
        proxies:
          - {name: 日本 01, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: 日本出口, type: select, proxies: [日本 01]}
        rule-providers:
          netflix: {type: http, behavior: domain, format: mrs, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs", path: ./netflix.mrs, interval: 86400}
          tg: {type: http, behavior: ipcidr, format: mrs, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs", path: ./tg.mrs, interval: 86400}
        rules:
          - RULE-SET,netflix,日本出口
          - RULE-SET,tg,日本出口,no-resolve
          - GEOSITE,category-ai-!cn,日本出口
          - GEOIP,CN,DIRECT
          - MATCH,DIRECT
        """
        var session = Session(title: "lookup", source: .pasted, text: config)
        session.exitsConfirmed = true
        store.sessions = [session]
        store.select(session.id)
        #expect(store.usedRuleSets() == ["geosite:netflix": "日本出口", "geoip:telegram": "日本出口",
                                         "geosite:category-ai-!cn": "日本出口", "geoip:cn": "DIRECT"])
        #expect(store.canEditFromLookup)
        store.routeWithRuleSet(source: "metacubex-geosite", name: "jal")
        #expect(store.showingRuleSetSheet && store.ruleSetPrefill == RuleSetPrefill(source: "metacubex-geosite", name: "jal"))
        store.draftInstruction("jal.co.jp 走 ")
        #expect(store.composerText == "jal.co.jp 走 ")
    }

    @Test func deepSeekSearchBorrowsTheAIServiceKey() throws {
        let store = makeStore()
        try store.keyStore.save("sk-deepseek", for: "deepSeek")
        store.searchSettings = SearchSettings(enabled: true, provider: .deepSeek)
        #expect(store.searchConfig == SearchConfig(provider: .deepSeek, apiKey: "sk-deepseek"))
        store.searchSettings.enabled = false
        #expect(store.searchConfig == nil)
    }

    @Test func zhipuSearchBorrowsItsKeyAndPerplexityUsesItsOwn() throws {
        let store = makeStore()
        try store.keyStore.save("zp-key", for: "zhipu")
        try store.keyStore.save("pplx-key", for: "search.perplexity")
        store.searchSettings = SearchSettings(enabled: true, provider: .zhipu)
        #expect(store.searchConfig == SearchConfig(provider: .zhipu, apiKey: "zp-key"))
        store.searchSettings.provider = .perplexity
        #expect(store.searchConfig == SearchConfig(provider: .perplexity, apiKey: "pplx-key"))
    }

    @Test func exportRefusesTheOriginalFileAndWritesTheDraft() async throws {
        let store = makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("config.yaml")
        try SampleConfig.text.write(to: source, atomically: true, encoding: .utf8)
        store.prepareImport(file: source)
        store.confirmPendingImport()
        store.confirmExits()
        let link = directory.appendingPathComponent("alias.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: EditorError.self) { try await store.export(to: link, validate: false) }

        store.send("example.org 直连")
        await waitIdle(store)
        store.write()
        let out = directory.appendingPathComponent("out.yaml")
        try await store.export(to: out, validate: true)
        #expect(try String(contentsOf: out, encoding: .utf8) == store.current?.draftText)
        #expect(store.current?.hasUnexportedChanges == false)
        #expect(try String(contentsOf: source, encoding: .utf8) == SampleConfig.text)
    }

    @Test func base64SubscriptionsImportAsGeneratedConfigs() throws {
        let store = makeStore()
        let links = "trojan://pw@jp.example.invalid:443?sni=jp.example.invalid#JP 01\nss://\(Data("aes-128-gcm:pw".utf8).base64EncodedString())@us.example.invalid:8388#US 01"
        store.importText(Data(links.utf8).base64EncodedString())
        let session = try #require(store.current)
        #expect(session.title == "粘贴的配置")
        #expect(session.importNote?.contains("Base64 订阅") == true)
        #expect(store.draft?.targets.map(\.name).contains("日本节点") == true)
        #expect(store.regions["日本节点"] == .jp)
        store.importText("not a config")
        guard case .failed(let message) = store.importStage else { Issue.record("expected failure"); return }
        #expect(message.contains("无法识别"))
    }

    @Test func importPreviewWaitsForConfirmation() throws {
        let store = makeStore()
        let before = store.sessions.count
        store.openImport(prefill: SampleConfig.text)
        #expect(store.showingImport)
        store.submitImportInput()
        guard case .preview(let pending) = store.importStage else { Issue.record("expected preview"); return }
        #expect(pending.title == "粘贴的配置" && pending.analysis?.proxyCount == 5 && pending.link == nil)
        #expect(store.sessions.count == before)
        store.cancelImport()
        #expect(store.sessions.count == before && !store.showingImport)
        store.openImport(prefill: SampleConfig.text)
        store.submitImportInput()
        store.confirmPendingImport()
        #expect(store.sessions.count == before + 1 && store.current?.exitsConfirmed == false)
    }

    @Test func cleanupOptionsReparseThePreviewInPlace() throws {
        let store = makeStore()
        let links = ["trojan://pw@info.example.invalid:443#剩余流量：12 GB", "trojan://pw@jp.example.invalid:443#JP 01",
                     "trojan://pw@jp.example.invalid:443#JP 01 copy"].joined(separator: "\n")
        store.openImport(prefill: links)
        store.submitImportInput()
        guard case .preview(let first) = store.importStage else { Issue.record("expected preview"); return }
        #expect(first.result.nodeCount == 1 && first.result.note?.contains("已移除 1 个信息节点") == true)
        store.setPendingImportOptions(ImportOptions(removeInfoNodes: false, removeDuplicates: true, addRegionFlags: true))
        guard case .preview(let second) = store.importStage else { Issue.record("expected preview"); return }
        #expect(second.id == first.id && second.options.addRegionFlags && second.result.nodeCount == 2)
        store.confirmPendingImport()
        #expect(store.draft?.targets.map(\.name).contains("🇯🇵 JP 01") == true)
        #expect(store.current?.importNote?.contains("为 1 个节点添加了地区旗帜") == true)
    }

    @Test func linksAreRecognizedAndValidated() {
        let store = makeStore()
        store.openImport(prefill: "http://sub.example.invalid/x")
        store.submitImportInput()
        // Not HTTPS, so it is content, which is not a configuration.
        guard case .failed = store.importStage else { Issue.record("expected failure"); return }
        #expect(SubscriptionFetcher.looksLikeLink(" https://sub.example.invalid/api?token=1 \n"))
        #expect(!SubscriptionFetcher.looksLikeLink("https://a.example.invalid\nhttps://b.example.invalid"))
    }

    /// Views read these on every render; with a large subscription they must stay cheap.
    @Test func derivedValuesAreCachedForLargeConfigs() throws {
        let regions = ["日本", "美国", "香港", "新加坡", "台湾"]
        var yaml = "proxies:\n"
        for i in 0..<400 { yaml += "  - {name: \"\(regions[i % 5]) \(i)\", type: ss, server: n\(i).invalid, port: 443, cipher: aes-128-gcm, password: p}\n" }
        yaml += "proxy-groups:\n"
        for g in 0..<120 { yaml += "  - {name: G\(g), type: select, proxies: [\((0..<400).map { "\"\(regions[$0 % 5]) \($0)\"" }.joined(separator: ", "))]}\n" }
        yaml += "rules:\n" + (0..<300).map { "  - DOMAIN-SUFFIX,d\($0).example,G\($0 % 120)\n" }.joined() + "  - MATCH,G0\n"
        let store = makeStore()
        store.importText(yaml, title: "large.yaml")
        store.confirmExits()
        _ = store.regions; _ = store.draft; _ = store.addedRules; _ = store.subtitle
        let start = Date()
        for _ in 0..<500 {
            _ = store.regions; _ = store.draft; _ = store.original; _ = store.addedRules; _ = store.subtitle; _ = store.conversationToken
        }
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(store.regions.count == 520 && store.regions["日本 0"] == .jp)
    }

    @Test func onlineRuleSetsGoThroughReview() async throws {
        let store = makeStore()
        let jp = try #require(store.draft?.target(named: "日本出口")?.id)
        store.addRuleSet(.catalog(source: "metacubex-geosite", name: "youtube"), targetID: jp)
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        #expect(turn.prompt == "添加规则集 MetaCubeX geosite/youtube → 日本出口")
        #expect(turn.steps.first?.detail == "手动添加")
        #expect(turn.proposal?.items.first?.provider?.verification == .verified)
        #expect(store.current?.draftText == SampleConfig.text)
        store.write()
        #expect(store.draft?.rules.first == "RULE-SET,youtube,日本出口")
        #expect(store.draft?.providers.first?.key == "youtube")

        store.addRuleSet(.url("https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanAD.list", behavior: "classical"),
                         targetID: try #require(store.draft?.target(named: "REJECT")?.id))
        await waitIdle(store)
        #expect(store.current?.turns.last?.proposal?.items.first?.provider?.behavior == "classical")
        store.send("/ruleset")
        #expect(store.showingRuleSetSheet)
    }

    @Test func newGroupsCanBeEditedBeforeWriting() async throws {
        let store = makeStore()
        let yaml = """
        proxies:
          - {name: "🇹🇼 台北 01", type: ss, server: tw1.invalid, port: 443, cipher: aes-128-gcm, password: p}
          - {name: "🇭🇰 香港 01", type: ss, server: hk1.invalid, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: 🚀 Proxy, type: select, proxies: ["🇹🇼 台北 01", "🇭🇰 香港 01"]}
        rules:
          - MATCH,🚀 Proxy
        """
        store.importText(yaml, title: "twhk.yaml")
        store.confirmExits()
        store.send("巴哈姆特走台湾和香港")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        let item = try #require(turn.proposal?.items.first { $0.kind == .group })
        store.editNewGroup(GroupEditTarget(turnID: turn.id, itemID: item.id), name: "巴哈", type: "url-test", members: ["🇭🇰 香港 01", "DIRECT"])
        #expect(!store.canWrite(store.current!.turns.last!))
        await waitIdle(store)
        let edited = try #require(store.current?.turns.last?.proposal)
        #expect(edited.items.first?.group?.name == "巴哈" && edited.items.first?.group?.members == ["🇭🇰 香港 01", "DIRECT"])
        #expect(edited.items.last?.targetName == "巴哈")
        store.write()
        let group = try #require(ProfileAnalysis.analyze(store.current!.draftText)?.groups.last)
        #expect(group.name == "巴哈" && group.type == "URLTest" && group.members.map(\.name) == ["🇭🇰 香港 01", "DIRECT"])
        #expect(store.draft?.rules.first == "RULE-SET,bahamut,巴哈")
    }

    @Test func commandsRouteToTheInspector() {
        let store = makeStore()
        store.send("/test www.example.com")
        #expect(store.inspectorTab == .test && store.testQuery == "www.example.com")
        #expect(store.current?.turns.isEmpty == true)
    }
}
