import Foundation
import Testing
@testable import VeerCore

private func sample() throws -> ConfigDocument { try ConfigDocument.parse(SampleConfig.text) }
private func id(_ name: String, in doc: ConfigDocument) -> String { doc.target(named: name)!.id }

struct ConfigDocumentTests {
    @Test func readsTargetsInOrder() throws {
        let doc = try sample()
        #expect(doc.targets.map(\.name).prefix(4) == ["日本出口", "美国出口", "香港出口", "自动选择"])
        #expect(doc.targets.suffix(2).map(\.name) == ["DIRECT", "REJECT"])
        #expect(doc.targets.map(\.id) == (0..<doc.targets.count).map { "target-\($0)" })
        #expect(doc.counts == .init(nodes: 5, groups: 4, rules: 8, providers: 0))
        #expect(doc.warnings.isEmpty)
    }

    @Test(arguments: [
        ("", "空的"),
        ("- a\n- b\n", "顶层必须是 YAML 映射"),
        ("rules: hello\n", "rules 必须是数组"),
        ("proxies:\n  - {name: a, type: ss}\n  - {name: a, type: ss}\n", "名称重复"),
        ("proxy-groups:\n  - {name: g, type: select, proxies: [missing]}\n", "不存在的出口"),
        ("proxy-groups:\n  - {name: a, type: select, proxies: [b]}\n  - {name: b, type: select, proxies: [a]}\n", "循环引用"),
        ("a: 1\na: 2\n", "重复"),
        ("rules: [\n", "YAML 无法解析"),
    ])
    func rejectsInvalidConfigurations(input: String, expected: String) {
        #expect {
            try ConfigDocument.parse(input)
        } throws: { error in
            (error as? EditorError)?.message.contains(expected) == true
        }
    }

    @Test func warnsWithoutMatchAndNonRuleMode() throws {
        let doc = try ConfigDocument.parse("mode: global\nrules:\n  - DOMAIN,a.com,DIRECT\n")
        #expect(doc.warnings.count == 3)
    }

    @Test func infersRegions() {
        #expect(Region.infer(from: "🇯🇵 东京 01") == .jp)
        #expect(Region.infer(from: "US-LA") == .us)
        #expect(Region.infer(from: "自动选择") == .unknown)
        #expect(Region.infer(from: "日本-美国 中转") == .unknown)
    }
}

struct PlanTests {
    @Test func decodesPlanAndClarification() throws {
        let reply = try EditPlan.decodeReply(#"```json\#n{"schemaVersion":1,"operations":[{"kind":"rule_set","source":"metacubex-geosite","name":"netflix","targetId":"target-0"}]}\#n```"#)
        #expect(reply == .plan(EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: "target-0")])))
        #expect(try EditPlan.decodeReply(#"{"clarification":"走哪个出口？"}"#) == .clarification("走哪个出口？", options: []))
    }

    @Test(arguments: [
        #"{"clarification":"?","operations":[]}"#,
        #"{"schemaVersion":2,"operations":[{"kind":"remove_rule","matchType":"DOMAIN","match":"a.com"}]}"#,
        #"{"schemaVersion":1,"operations":[]}"#,
        #"{"schemaVersion":1,"operations":[{"kind":"route","matchType":"DOMAIN","match":"a.com","targetId":"t","noResolve":true}]}"#,
        #"{"schemaVersion":1,"operations":[{"kind":"set_dns"}]}"#,
        "not json",
    ])
    func rejectsMalformedReplies(content: String) {
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(content) }
    }
}

struct ApplyTests {
    @Test func addsRuleSetsAtTopAndPreservesEverythingElse() throws {
        let doc = try sample()
        let plan = EditPlan(operations: [
            .ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: id("日本出口", in: doc)),
            .ruleSet(.catalog(source: "metacubex-geosite", name: "openai"), targetId: id("美国出口", in: doc)),
        ])
        let result = try PlanApplier.apply(plan, to: doc)
        let after = try ConfigDocument.parse(result.candidate)
        #expect(after.rules.prefix(2) == ["RULE-SET,netflix,日本出口", "RULE-SET,openai,美国出口"])
        #expect(after.rules.count == 10)
        #expect(after.providers.map(\.key) == ["netflix", "openai"])
        #expect(after.providers[0].url == "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/netflix.mrs")
        #expect(result.items.map(\.subject) == ["Netflix", "ChatGPT"])
        // Everything before `rule-providers` is byte-identical, including the header comment.
        let prefix = SampleConfig.text.components(separatedBy: "rules:")[0]
        #expect(result.candidate.hasPrefix(prefix))
        #expect(result.candidate.contains("rule-providers:\n  netflix:\n    type: http\n    behavior: domain\n    format: mrs\n"))
        #expect(result.candidate.contains("interval: 86400"))
    }

    @Test func routeReplacesExistingRuleAndKeepsNoResolve() throws {
        let doc = try ConfigDocument.parse("""
        proxy-groups:
          - {name: HK, type: select, proxies: [DIRECT]}
        rules:
          # local network
          - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
          - DOMAIN-SUFFIX,a.com,DIRECT # keep me
          - MATCH,DIRECT
        """)
        let plan = EditPlan(operations: [.route(matchType: "IP-CIDR", match: "192.168.0.0/16", targetId: id("HK", in: doc))])
        let result = try PlanApplier.apply(plan, to: doc)
        #expect(result.items[0].replaced == ["IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"])
        #expect(result.candidate == """
        proxy-groups:
          - {name: HK, type: select, proxies: [DIRECT]}
        rules:
          # local network
          - IP-CIDR,192.168.0.0/16,HK,no-resolve
          - DOMAIN-SUFFIX,a.com,DIRECT # keep me
          - MATCH,DIRECT
        """)
    }

    @Test func handlesUnindentedSequencesAndQuoting() throws {
        let doc = try ConfigDocument.parse("proxy-groups:\n- name: 'JP: 1'\n  type: select\n  proxies: [DIRECT]\nrules:\n- MATCH,DIRECT\n")
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN", match: "x.com", targetId: id("JP: 1", in: doc))])
        let result = try PlanApplier.apply(plan, to: doc)
        #expect(result.candidate.hasSuffix("rules:\n- 'DOMAIN,x.com,JP: 1'\n- MATCH,DIRECT\n"))
    }

    @Test func rerendersFlowRulesAndCreatesMissingRules() throws {
        let flow = try ConfigDocument.parse("mode: rule\nrules: ['MATCH,DIRECT']\n")
        let direct = id("DIRECT", in: flow)
        let a = try PlanApplier.apply(EditPlan(operations: [.route(matchType: "DOMAIN", match: "a.com", targetId: direct)]), to: flow)
        #expect(a.candidate == "mode: rule\nrules:\n  - DOMAIN,a.com,DIRECT\n  - MATCH,DIRECT\n")
        let none = try ConfigDocument.parse("mode: rule\n")
        let b = try PlanApplier.apply(EditPlan(operations: [.route(matchType: "DOMAIN", match: "a.com", targetId: id("DIRECT", in: none))]), to: none)
        #expect(b.candidate == "mode: rule\nrules:\n  - DOMAIN,a.com,DIRECT\n")
    }

    @Test func reusesProvidersByURLAndAvoidsKeyCollisions() throws {
        let doc = try ConfigDocument.parse("""
        rule-providers:
          netflix:
            type: http
            behavior: classical
            url: https://example.invalid/other.list
            path: ./n.list
        rules:
          - MATCH,DIRECT
        """)
        let plan = EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: id("DIRECT", in: doc))])
        let result = try PlanApplier.apply(plan, to: doc)
        #expect(result.items[0].provider?.key == "netflix-veer")
        let again = try PlanApplier.apply(plan, to: try ConfigDocument.parse(result.candidate))
        #expect(again.items[0].provider?.reused == true)
        #expect(!again.changed)
    }

    @Test func partialAcceptanceWritesOnlyAcceptedItems() throws {
        let doc = try sample()
        let plan = EditPlan(operations: [
            .ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: id("日本出口", in: doc)),
            .route(matchType: "DOMAIN-SUFFIX", match: "openai.com", targetId: id("美国出口", in: doc)),
        ])
        let result = try PlanApplier.apply(plan, to: doc, accepting: [1])
        let after = try ConfigDocument.parse(result.candidate)
        #expect(after.providers.isEmpty)
        #expect(after.rules.first == "DOMAIN-SUFFIX,openai.com,美国出口")
        #expect(!after.rules.contains("DOMAIN-SUFFIX,openai.com,DIRECT"))
    }

    @Test(arguments: [
        EditPlan(operations: [.removeRule(matchType: "DOMAIN", match: "nope.com")]),
        EditPlan(operations: [.route(matchType: "DOMAIN", match: "bad domain", targetId: "target-0")]),
        EditPlan(operations: [.route(matchType: "IP-CIDR", match: "10.0.0.0/33", targetId: "target-0")]),
        EditPlan(operations: [.route(matchType: "PROCESS-NAME", match: "curl", targetId: "target-0")]),
        EditPlan(operations: [.route(matchType: "DOMAIN", match: "a.com", targetId: "target-99")]),
        EditPlan(operations: [.route(matchType: "DOMAIN", match: "a.com", targetId: "target-0"), .removeRule(matchType: "DOMAIN", match: "A.com")]),
        EditPlan(operations: [.ruleSet(.url("https://evil.example/x.list", behavior: nil), targetId: "target-0")]),
        EditPlan(operations: [.ruleSet(.catalog(source: "unknown", name: "x"), targetId: "target-0")]),
    ])
    func rejectsUnsafePlans(plan: EditPlan) throws {
        let doc = try sample()
        #expect(throws: EditorError.self) { try PlanApplier.apply(plan, to: doc) }
    }

    @Test func rejectsFlowRuleProviders() throws {
        let doc = try ConfigDocument.parse("rule-providers: {a: {type: http, url: 'https://x.invalid/a.list', path: ./a}}\nrules:\n  - MATCH,DIRECT\n")
        let plan = EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: id("DIRECT", in: doc))])
        #expect(throws: EditorError.self) { try PlanApplier.apply(plan, to: doc) }
    }

    @Test func keepsCRLFLineEndings() throws {
        let doc = try ConfigDocument.parse("mode: rule\r\nrules:\r\n  - MATCH,DIRECT\r\n")
        let result = try PlanApplier.apply(EditPlan(operations: [.route(matchType: "DOMAIN", match: "a.com", targetId: id("REJECT", in: doc))]), to: doc)
        #expect(result.candidate == "mode: rule\r\nrules:\r\n  - DOMAIN,a.com,REJECT\r\n  - MATCH,DIRECT\r\n")
    }
}

struct LocalParserTests {
    func parse(_ text: String) throws -> AssistantReply {
        let doc = try sample()
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        return try LocalIntentParser.parse(text, targets: doc.targets, regions: regions)
    }

    @Test func parsesTheHeadlineExample() throws {
        let doc = try sample()
        #expect(try parse("Netflix 走日本，ChatGPT 走美国") == .plan(EditPlan(operations: [
            .ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: id("日本出口", in: doc)),
            .ruleSet(.catalog(source: "metacubex-geosite", name: "openai"), targetId: id("美国出口", in: doc)),
        ])))
    }

    @Test func parsesDomainsDirectRejectMentionsAndRemoval() throws {
        let doc = try sample()
        #expect(try parse("example.org 直连") == .plan(EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "example.org", targetId: id("DIRECT", in: doc))])))
        #expect(try parse("屏蔽广告") == .plan(EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "category-ads-all"), targetId: id("REJECT", in: doc))])))
        #expect(try parse("YouTube 走 @Premium-SG-Netflix-Unlock-IEPL-02-高速专线") == .plan(EditPlan(operations: [
            .ruleSet(.catalog(source: "metacubex-geosite", name: "youtube"), targetId: id("Premium-SG-Netflix-Unlock-IEPL-02-高速专线", in: doc)),
        ])))
        #expect(try parse("删除 example.com 的规则") == .plan(EditPlan(operations: [.removeRule(matchType: "DOMAIN-SUFFIX", match: "example.com")])))
    }

    @Test func asksOrExplainsInsteadOfGuessing() throws {
        guard case .clarification(_, let options) = try parse("YouTube 走代理") else { Issue.record("expected clarification"); return }
        #expect(options.map(\.label) == ["日本出口", "美国出口", "香港出口", "自动选择"])
        #expect(options[0].prompt == "YouTube 走 @日本出口")
        #expect(try parse("节点太卡了换一个") == .outOfScope(LocalIntentParser.outOfScopeMessage))
        guard case .clarification = try parse("Netflix 走德国") else { Issue.record("expected clarification"); return }
        // Excluding a region is actionable: a group of every other known region.
        guard case .plan(let excluded) = try parse("Netflix 不要走日本"), case .group(let exclusion) = excluded.operations.first else {
            Issue.record("expected exclusion group"); return
        }
        #expect(exclusion.excludeRegions == [.jp] && exclusion.regions.isEmpty)
        // Several regions for one service now create a group named after it.
        guard case .plan(let multi) = try parse("Netflix 走日本和美国"), case .group(let group) = multi.operations.first else {
            Issue.record("expected a new group"); return
        }
        #expect(group.name == "Netflix" && group.regions == [.jp, .us])
        #expect(throws: EditorError.self) { try parse("帮我优化一下") }
    }
}

struct ClarificationLoopTests {
    /// The reported loop: four JP nodes and no JP group made every answer ask again.
    @Test func answeringResolvesInsteadOfRepeating() throws {
        let yaml = """
        proxies:
          - {name: "[A]JP PrivateNET 01", type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "[A]JP PrivateNET 02", type: ss, server: b.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "[A]US PrivateNET 01", type: ss, server: c.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: "[A]US PrivateNET 02", type: ss, server: d.invalid, port: 1, cipher: aes-128-gcm, password: p}
        rules:
          - MATCH,DIRECT
        """
        let doc = try ConfigDocument.parse(yaml)
        let regions = Session(title: "", source: .pasted, text: yaml).regions(for: doc.targets)
        var prompt = "Netflix 走日本，ChatGPT 走美国"
        var asked = 0
        while true {
            switch try LocalIntentParser.parse(prompt, targets: doc.targets, regions: regions) {
            case .clarification(_, let options):
                asked += 1
                #expect(asked <= 2, "asked again: \(prompt)")
                if asked > 2 { return }
                prompt = try #require(options.first?.prompt)
            case .plan(let plan):
                #expect(prompt == "Netflix 走@[A]JP PrivateNET 01，ChatGPT 走@[A]US PrivateNET 01")
                #expect(plan.operations.count == 2)
                #expect(try ConfigDocument.parse(PlanApplier.apply(plan, to: doc).candidate).rules.prefix(2)
                        == ["RULE-SET,netflix,[A]JP PrivateNET 01", "RULE-SET,openai,[A]US PrivateNET 01"])
                return
            case .outOfScope:
                Issue.record("unexpected out-of-scope"); return
            }
        }
    }

    @Test func regionLettersInsideExitNamesAreNotRegionRequests() throws {
        let yaml = "proxies:\n  - {name: 'US-JP Relay', type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}\nrules:\n  - MATCH,DIRECT\n"
        let doc = try ConfigDocument.parse(yaml)
        guard case .plan = try LocalIntentParser.parse("YouTube 走 @US-JP Relay", targets: doc.targets, regions: [:]) else {
            Issue.record("expected plan"); return
        }
    }
}

struct PrivacyTests {
    @Test func anonymizesNamesAndPromptsLongestFirst() throws {
        let doc = try sample()
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        let context = AnonymousContext(targets: doc.targets, regions: regions)
        #expect(context.exits[0].label == "策略组1（日本）")
        #expect(context.exits[3].label == "策略组4")
        #expect(context.exits[4].label == "节点1（日本）")
        #expect(context.anonymize("Netflix 走 @日本出口，YouTube 走香港出口") == "Netflix 走 策略组1（日本），YouTube 走策略组3（香港）")
        let system = AIClient.systemPrompt(config: AnonymizedConfig.make(document: doc, regions: regions).yaml)
        for secret in ["placeholder-password", "example.invalid", "日本出口", "东京", "DOMAIN-SUFFIX,openai.com"] {
            #expect(!system.contains(secret))
        }
    }

    @Test func payloadContainsOnlyAnonymousData() throws {
        let doc = try sample()
        let request = EditorEngine.Request(prompt: "Netflix 走日本出口", draft: doc, regions: [:], useAI: true, settings: AISettings(), apiKey: "sk-test")
        let payload = EditorEngine.payload(for: request)
        #expect(payload.instruction == "Netflix 走策略组1")
        #expect(payload.config?.contains("name: 策略组1") == true)
        #expect(!payload.readable.contains("sk-test"))
        #expect(!payload.readable.contains("password"))
    }
}

struct DiffAndMatchTests {
    @Test func diffsLines() {
        let lines = LineDiff.diff("a\nb\nc\n", "a\nx\nc\nd\n")
        #expect(lines.map(\.kind) == [.same, .removed, .added, .same, .added])
        #expect(LineDiff.stats(lines) == (2, 1))
        #expect(lines.last?.newNumber == 4)
        let long = (1...40).map { "line\($0)" }.joined(separator: "\n")
        let blocks = LineDiff.blocks(LineDiff.diff(long, long.replacingOccurrences(of: "line20", with: "changed")))
        #expect(blocks.contains { if case .folded(_, let count, _) = $0 { count == 16 } else { false } })
    }

    @Test func patienceKeepsRepeatedBlocksTogether() {
        let old = "providers:\n  a:\n    type: http\n    url: A\nrules:\n  - RULE-SET,a,X\n"
        let new = "providers:\n  a:\n    type: http\n    url: A\n  b:\n    type: http\n    url: B\nrules:\n  - RULE-SET,b,Y\n  - RULE-SET,a,X\n"
        let added = LineDiff.diff(old, new).filter { $0.kind == .added }.map(\.text)
        #expect(added == ["  b:", "    type: http", "    url: B", "  - RULE-SET,b,Y"])
    }

    @Test func matchesDomainsAndReportsSkippedRules() {
        let rules = ["RULE-SET,netflix,JP", "DOMAIN-SUFFIX,example.com,DIRECT", "DOMAIN-KEYWORD,google,US", "GEOIP,CN,DIRECT", "MATCH,Auto"]
        let hit = RuleMatcher.match(domain: "www.example.com", rules: rules)
        #expect(hit.index == 1 && hit.target == "DIRECT" && hit.skipped.count == 1)
        let fallback = RuleMatcher.match(domain: "www.netflix.com", rules: rules)
        #expect(fallback.index == 4 && fallback.target == "Auto" && fallback.skipped.map(\.index) == [0, 3])
        #expect(RuleMatcher.normalize("https://WWW.Example.com/path") == "www.example.com")
        #expect(RuleMatcher.normalize("not a domain") == nil)
    }
}

struct StorageTests {
    @Test func roundTripsSessionsWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        var session = Session(title: "a.yaml", source: .subscription(host: "sub.example.net"), text: SampleConfig.text)
        session.turns.append(Turn(prompt: "x", mode: .local, steps: [.init(id: 0, title: "理解指令", state: .running)]))
        try store.save(session)
        let loaded = try #require(store.loadAll().first)
        #expect(loaded.id == session.id)
        #expect(loaded.turns[0].outcome == .cancelled)
        #expect(loaded.turns[0].steps[0].state == .cancelled)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(session.id).json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        store.delete(session.id)
        #expect(store.loadAll().isEmpty)
    }
}

struct ValidatorTests {
    @Test func redactsSecretsFromKernelOutput() {
        let yaml = "proxies:\n  - name: a\n    server: secret.host.example\n    password: hunter2-secret\n"
        let output = "\u{1B}[31merror\u{1B}[0m dial secret.host.example with hunter2-secret at /tmp/veer-x"
        #expect(MihomoValidator.redact(output, yaml: yaml, directory: "/tmp/veer-x") == "error dial [已隐藏] with [已隐藏] at [临时目录]")
    }

    @Test func reportsUnavailableWithoutBinary() async {
        let result = await MihomoValidator(binary: nil).validate("mode: rule\n")
        #expect(result.status == .unavailable)
    }
}

struct AIClientTests {
    struct StubTransport: AITransport {
        let status: Int
        let body: String
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func validatesEndpoints() throws {
        #expect(try AIClient.endpoint(for: "https://api.deepseek.com/v1/").absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(try AIClient.endpoint(for: "http://127.0.0.1:11434/v1").absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        for bad in ["http://api.example.com/v1", "https://u:p@api.example.com", "https://api.example.com/v1?key=1", "nonsense"] {
            #expect(throws: AIFailure.self) { try AIClient.endpoint(for: bad) }
        }
    }

    @Test func classifiesFailures() async throws {
        let settings = AISettings()
        let request = try AIClient().makeRequest(settings: settings, apiKey: "k", system: "s", history: [], prompt: "p")
        let cases: [(Int, String, AIFailure)] = [
            (401, "", .unauthorized(401)), (429, "", .rateLimited), (502, "", .server(502)),
            (200, #"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#, .invalidResponse("AI 的回答没有完整结束，请缩短指令或检查模型设置后重试。")),
        ]
        for (status, body, expected) in cases {
            await #expect(throws: expected) { try await AIClient(transport: StubTransport(status: status, body: body)).complete(request) }
        }
        let ok = try await AIClient(transport: StubTransport(status: 200, body: #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"clarification\":\"哪个？\"}"}}]}"#)).complete(request)
        #expect(ok == #"{"clarification":"哪个？"}"#)
        #expect(throws: AIFailure.missingKey) { try AIClient().makeRequest(settings: settings, apiKey: nil, system: "", history: [], prompt: "") }
    }
}

struct EngineFlowTests {
    struct PassValidator: ConfigValidating {
        func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }
        var versionDescription: String? { "test" }
    }
    struct OfflineVerifier: RuleSetVerifying {
        let status: RuleSetVerification
        func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, status) }) }
    }

    @Test func runsLocalPipelineToProposal() async throws {
        let doc = try sample()
        let engine = EditorEngine(validator: PassValidator(), verifier: OfflineVerifier(status: .verified))
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        let output = try await engine.run(.init(prompt: "Netflix 走日本，ChatGPT 走美国", draft: doc, regions: regions, useAI: false, settings: AISettings(), apiKey: nil)) { _ in }
        guard case let .proposal(plan, items, candidate, validation) = output else { Issue.record("expected proposal"); return }
        #expect(items.allSatisfy { $0.provider?.verification == .verified })
        #expect(validation.status == .passed)
        let partial = try await engine.reapply(plan: plan, accepted: [0], draft: doc, previous: items)
        #expect(partial.candidate != candidate)
        #expect(try ConfigDocument.parse(partial.candidate).providers.map(\.key) == ["netflix"])
    }

    @Test func rejectsMissingRuleSets() async throws {
        let doc = try sample()
        let engine = EditorEngine(validator: PassValidator(), verifier: OfflineVerifier(status: .missing))
        await #expect(throws: EditorError.self) {
            _ = try await engine.run(.init(prompt: "Netflix 走日本出口", draft: doc, regions: [:], useAI: false, settings: AISettings(), apiKey: nil)) { _ in }
        }
    }
}
