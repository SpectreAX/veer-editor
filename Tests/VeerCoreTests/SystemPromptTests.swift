import Foundation
import Testing
@testable import VeerCore

func regionsOfSample() -> [String: Region] {
    let doc = try! ConfigDocument.parse(SampleConfig.text)
    return Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
}

struct SystemPromptTests {
    func context() throws -> (ConfigDocument, AnonymousContext) {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        return (doc, AnonymousContext(targets: doc.targets, regions: regions))
    }

    @Test func describesVeerNotOpenClashAndOnlyAnonymousExits() throws {
        _ = try context()
        let prompt = SystemPrompt.build(config: AnonymizedConfig.make(document: try ConfigDocument.parse(SampleConfig.text), regions: regionsOfSample()).yaml)
        #expect(prompt.contains("Veer 不是 OpenClash"))
        #expect(prompt.contains(#"{"understanding":"…","schemaVersion":1,"operations":[…]}"#))
        #expect(prompt.contains(SystemPrompt.askForExit))
        #expect(prompt.contains("Ruleset/ 前缀"))
        #expect(prompt.contains("{id: target-0, name: 策略组1（日本）}") || prompt.contains("name: 策略组1（日本）"))
        for leaked in ["日本出口", "东京", "example.invalid", "placeholder-password", "DOMAIN-SUFFIX,openai.com"] {
            #expect(!prompt.contains(leaked))
        }
        // No OpenClash-specific workflow survives the adaptation.
        for openClash in ["$CONFIG_FILE", "配置管理", "覆写脚本粘贴", "type'=>'file"] {
            #expect(!prompt.contains(openClash))
        }
    }

    /// Every JSON example in the prompt must be a reply Veer accepts.
    @Test func examplesDecodeAndApply() throws {
        let (doc, _) = try context()
        let prompt = SystemPrompt.build(config: AnonymizedConfig.make(document: doc, regions: regionsOfSample()).yaml)
        let direct = doc.target(named: "DIRECT")!.id, reject = doc.target(named: "REJECT")!.id
        let section = prompt.components(separatedBy: "# 示例")[1].components(separatedBy: "# Targets")[0]
        let examples = section.components(separatedBy: "\n").filter { $0.hasPrefix("{\"") }
        #expect(examples.count == 6)
        for line in examples {
            let json = line.replacingOccurrences(of: "<DIRECT 的 id>", with: direct).replacingOccurrences(of: "<REJECT 的 id>", with: reject)
            switch try EditPlan.decodeReply(json) {
            case .clarification(let text, _): #expect(text == SystemPrompt.askForExit)
            case .plan(let plan): #expect(try PlanApplier.apply(plan, to: doc).changed)
            case .outOfScope, .search: Issue.record("unexpected reply")
            }
        }
    }

    @Test func everyListedNameIsAValidCatalogEntry() throws {
        let sources: [(String, [String])] = [("metacubex-geosite", SystemPrompt.geositeNames), ("metacubex-geoip", SystemPrompt.geoipNames),
                                             ("acl4ssr", SystemPrompt.acl4ssrNames), ("blackmatrix7", SystemPrompt.blackmatrix7Names)]
        for (source, names) in sources {
            for name in names { _ = try RuleSetCatalog.spec(for: .catalog(source: source, name: name)) }
        }
        #expect(try RuleSetCatalog.spec(for: .catalog(source: "acl4ssr", name: "Ruleset/YouTube")).url
                == "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/YouTube.list")
    }

    @Test func pastedAddressesFollowThePromptsInferenceRules() throws {
        let geosite = try RuleSetCatalog.spec(for: .url("https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.mrs", behavior: nil))
        #expect(geosite.behavior == "domain" && geosite.format == "mrs")
        let geoip = try RuleSetCatalog.spec(for: .url("https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs", behavior: nil))
        #expect(geoip.behavior == "ipcidr" && geoip.key == "cn-ip")
        let list = try RuleSetCatalog.spec(for: .url("https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanAD.list", behavior: nil))
        #expect(list.behavior == "classical" && list.format == "text")
        #expect(throws: EditorError.self) { try RuleSetCatalog.spec(for: .url("https://example.com/x.mrs", behavior: "domain")) }
        #expect(throws: EditorError.self) { try RuleSetCatalog.spec(for: .url("https://cdn.jsdelivr.net/gh/a/b/x.mrs", behavior: "classical")) }
    }

    struct StubTransport: AITransport {
        let content: String
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    struct PassValidator: ConfigValidating {
        func validate(_ yaml: String) async -> ValidationResult { .init(status: .passed, message: "ok") }
        var versionDescription: String? { nil }
    }
    struct Verified: RuleSetVerifying {
        func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) }
    }

    /// The pasted OpenClash example ("我想让 YouTube 走代理") through an AI turn that follows the prompt.
    @Test func youtubeViaProxyAsksThenPlans() async throws {
        let (doc, _) = try context()
        func run(_ prompt: String, reply: String) async throws -> EditorEngine.Output {
            let engine = EditorEngine(ai: AIClient(transport: StubTransport(content: reply)), validator: PassValidator(), verifier: Verified())
            return try await engine.run(.init(prompt: prompt, draft: doc, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")) { _ in }
        }
        guard case .clarification(let question, let options) = try await run("我想让 YouTube 走代理", reply: #"{"clarification":"\#(SystemPrompt.askForExit)"}"#) else {
            Issue.record("expected clarification"); return
        }
        #expect(question == SystemPrompt.askForExit && options.map(\.label).contains("美国出口") && options.allSatisfy { $0.prompt == nil })
        let plan = #"{"schemaVersion":1,"operations":[{"kind":"rule_set","source":"metacubex-geosite","name":"youtube","targetId":"target-1"}]}"#
        guard case .proposal(_, let items, let candidate, _) = try await run("YouTube 走策略组2（美国）", reply: plan) else { Issue.record("expected proposal"); return }
        #expect(items.first?.subject == "YouTube" && items.first?.targetName == "美国出口")
        let after = try ConfigDocument.parse(candidate)
        #expect(after.rules.first == "RULE-SET,youtube,美国出口")
        #expect(after.providers.first?.url == "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.mrs")
        #expect(candidate.contains("    path: ./rule_provider/youtube.mrs\n    interval: 86400\n"))
    }
}

/// Checks that every rule-set name the prompt lists exists. Needs network: VEER_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_NETWORK_TESTS"] != nil))
struct RealRuleSetCatalogTests {
    @Test func listedNamesExist() async throws {
        var urls: [String] = []
        for (source, names) in [("metacubex-geosite", SystemPrompt.geositeNames), ("metacubex-geoip", SystemPrompt.geoipNames),
                                ("acl4ssr", SystemPrompt.acl4ssrNames), ("blackmatrix7", SystemPrompt.blackmatrix7Names)] {
            urls += try names.map { try RuleSetCatalog.spec(for: .catalog(source: source, name: $0)).url }
        }
        let results = await NetworkRuleSetVerifier().verify(urls)
        #expect(results.filter { $0.value != .verified }.keys.sorted() == [])
    }
}
