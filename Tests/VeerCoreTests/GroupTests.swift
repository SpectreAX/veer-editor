import Foundation
import Testing
import Yams
@testable import VeerCore

enum GroupFixture {
    static let yaml = """
    proxies:
      - {name: "🇹🇼 台北 01", type: ss, server: tw1.invalid, port: 443, cipher: aes-128-gcm, password: p}
      - {name: "🇹🇼 台北 02", type: ss, server: tw2.invalid, port: 443, cipher: aes-128-gcm, password: p}
      - {name: "🇭🇰 香港 01", type: ss, server: hk1.invalid, port: 443, cipher: aes-128-gcm, password: p}
      - {name: "🇯🇵 东京 01", type: ss, server: jp1.invalid, port: 443, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - name: 🚀 Proxy
        type: select
        proxies: ["🇹🇼 台北 01", "🇹🇼 台北 02", "🇭🇰 香港 01", "🇯🇵 东京 01"]
      - {name: 🍎 Apple, type: select, proxies: [DIRECT, 🚀 Proxy]}
    rules:
      - DOMAIN-SUFFIX,example.com,DIRECT
      - MATCH,🚀 Proxy
    """
    static func document() throws -> ConfigDocument { try ConfigDocument.parse(yaml) }
    static func regions(_ doc: ConfigDocument) -> [String: Region] { Session(title: "", source: .pasted, text: yaml).regions(for: doc.targets) }
}

struct GroupTests {
    @Test func oneServiceSeveralRegionsCreatesAGroup() throws {
        let doc = try GroupFixture.document()
        let regions = GroupFixture.regions(doc)
        for prompt in ["巴哈姆特走台湾和香港", "巴哈姆特 走 台湾、香港"] {
            guard case .plan(let plan) = try LocalIntentParser.parse(prompt, targets: doc.targets, regions: regions) else {
                Issue.record("expected plan for \(prompt)"); continue
            }
            #expect(plan.operations == [
                .group(.init(id: "new-1", name: "巴哈姆特", regions: [.tw, .hk])),
                .ruleSet(.catalog(source: "metacubex-geosite", name: "bahamut"), targetId: "new-1"),
            ])
            let result = try PlanApplier.apply(plan, to: doc, regions: regions)
            let after = try ConfigDocument.parse(result.candidate)
            #expect(after.rules.first == "RULE-SET,bahamut,巴哈姆特")
            let analysis = try #require(ProfileAnalysis.analyze(result.candidate))
            let group = try #require(analysis.groups.last)
            #expect(group.name == "巴哈姆特" && group.type == "Select")
            #expect(group.members.map(\.name) == ["🇹🇼 台北 01", "🇹🇼 台北 02", "🇭🇰 香港 01"])
            // Existing groups are untouched, byte for byte.
            #expect(result.candidate.contains("  - name: 🚀 Proxy\n    type: select\n    proxies: [\"🇹🇼 台北 01\""))
            #expect(result.candidate.contains("  - {name: 🍎 Apple, type: select, proxies: [DIRECT, 🚀 Proxy]}\n  - name: 巴哈姆特\n"))
            #expect(result.items.first?.group?.regionCounts == ["台湾": 2, "香港": 1])
        }
    }

    @Test func namesNeverCollideAndNamedExitsCanBeMembers() throws {
        let doc = try ConfigDocument.parse(GroupFixture.yaml.replacingOccurrences(of: "🍎 Apple", with: "巴哈姆特"))
        let regions = GroupFixture.regions(doc)
        let plan = EditPlan(operations: [.group(.init(id: "new-1", name: "巴哈姆特", type: "url-test", members: [doc.target(named: "🇯🇵 东京 01")!.id], )),
                                         .route(matchType: "DOMAIN-SUFFIX", match: "gamer.com.tw", targetId: "new-1")])
        let result = try PlanApplier.apply(plan, to: doc, regions: regions)
        #expect(try ConfigDocument.parse(result.candidate).rules.first == "DOMAIN-SUFFIX,gamer.com.tw,巴哈姆特 2")
        guard case .plan(let local) = try LocalIntentParser.parse("YouTube 走 @🇯🇵 东京 01 和 @🇭🇰 香港 01", targets: doc.targets, regions: regions) else {
            Issue.record("expected plan"); return
        }
        guard case .group(let group) = local.operations.first else { Issue.record("expected group"); return }
        #expect(group.members.count == 2 && group.regions.isEmpty)
    }

    @Test func rulesCannotPointAtARejectedGroup() throws {
        let doc = try GroupFixture.document()
        let plan = EditPlan(operations: [.group(.init(id: "new-1", name: "X", regions: [.tw])),
                                         .ruleSet(.catalog(source: "metacubex-geosite", name: "bahamut"), targetId: "new-1")])
        #expect(throws: EditorError.self) { try PlanApplier.apply(plan, to: doc, regions: GroupFixture.regions(doc), accepting: [1]) }
        let groupOnly = try PlanApplier.apply(plan, to: doc, regions: GroupFixture.regions(doc), accepting: [0])
        #expect(try ConfigDocument.parse(groupOnly.candidate).targets.contains { $0.name == "X" })
    }

    @Test func decodesAndValidatesGroupOperations() throws {
        let reply = try EditPlan.decodeReply(#"{"schemaVersion":1,"operations":[{"kind":"group","id":"new-1","name":"巴哈姆特","type":"url-test","regions":["tw","HK"]},{"kind":"rule_set","source":"metacubex-geosite","name":"bahamut","targetId":"new-1"}]}"#)
        guard case .plan(let plan) = reply, case .group(let group) = plan.operations[0] else { Issue.record("expected group"); return }
        #expect(group.regions == [.tw, .hk] && group.type == "url-test")
        for bad in [#"{"kind":"group","id":"g1","name":"A","regions":["TW"]}"#, #"{"kind":"group","id":"new-1","name":"A,B","regions":["TW"]}"#,
                    #"{"kind":"group","id":"new-1","name":"A","type":"load-balance","regions":["TW"]}"#, #"{"kind":"group","id":"new-1","name":"A","regions":["MARS"]}"#,
                    #"{"kind":"group","id":"new-1","name":"A"}"#, #"{"kind":"group","id":"new-1","name":"A","regions":["TW"],"proxies":["x"]}"#] {
            #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"schemaVersion":1,"operations":[\#(bad)]}"#) }
        }
    }

    @Test func explainsMissingRegionsAndHandlesLayouts() throws {
        let doc = try GroupFixture.document()
        let plan = EditPlan(operations: [.group(.init(id: "new-1", name: "DE", regions: [.de])), .route(matchType: "DOMAIN", match: "a.de", targetId: "new-1")])
        #expect { try PlanApplier.apply(plan, to: doc, regions: GroupFixture.regions(doc)) } throws: { ($0 as? EditorError)?.message.contains("德国") == true }

        let noGroups = try ConfigDocument.parse("proxies:\n  - {name: TW1, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}\nrules:\n  - MATCH,DIRECT\n")
        let created = try PlanApplier.apply(EditPlan(operations: [.group(.init(id: "new-1", name: "G", regions: [.tw])), .route(matchType: "DOMAIN", match: "a.tw", targetId: "new-1")]),
                                            to: noGroups, regions: ["TW1": .tw])
        #expect(created.candidate.contains("proxy-groups:\n  - name: G\n    type: select\n    proxies:\n    - TW1\nrules:"))
        let flow = try ConfigDocument.parse("proxies:\n  - {name: TW1, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}\nproxy-groups: [{name: A, type: select, proxies: [TW1]}]\nrules:\n  - MATCH,DIRECT\n")
        #expect(throws: EditorError.self) {
            try PlanApplier.apply(EditPlan(operations: [.group(.init(id: "new-1", name: "G", regions: [.tw]))]), to: flow, regions: ["TW1": .tw])
        }
    }

    @Test func aiPlanFollowingThePromptExample() async throws {
        struct Stub: AITransport {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let content = #"{"schemaVersion":1,"operations":[{"kind":"group","id":"new-1","name":"巴哈姆特","type":"select","regions":["TW","HK"]},{"kind":"rule_set","source":"metacubex-geosite","name":"bahamut","targetId":"new-1"}]}"#
                let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        struct Pass: ConfigValidating { func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }; var versionDescription: String? { nil } }
        struct Verified: RuleSetVerifying { func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) } }
        let doc = try GroupFixture.document()
        let engine = EditorEngine(ai: AIClient(transport: Stub()), validator: Pass(), verifier: Verified())
        let output = try await engine.run(.init(prompt: "巴哈姆特走台湾和香港", draft: doc, regions: GroupFixture.regions(doc), useAI: true, settings: AISettings(), apiKey: "k")) { _ in }
        guard case .proposal(_, let items, _, _) = output else { Issue.record("expected proposal"); return }
        #expect(items.map(\.kind) == [.group, .ruleSet])
        #expect(items[1].targetName == "巴哈姆特")
    }
}
