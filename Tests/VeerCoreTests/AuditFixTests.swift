import Foundation
import Testing
@testable import VeerCore

/// Regression tests for the defects in docs/TEST_REPORT_2026-10-19.md (D1–D12).
struct AuditFixTests {
    static func sample() throws -> (ConfigDocument, [String: Region]) {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        return (doc, Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets))
    }

    // D1
    @Test func ruleSetRulesCanBeRemoved() async throws {
        let (doc, regions) = try Self.sample()
        let target = doc.target(named: "日本出口")!.id
        let added = try ConfigDocument.parse(try PlanApplier.apply(EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: target)]), to: doc).candidate)
        guard case .plan(let plan) = try LocalIntentParser.parse("删除 Netflix 规则", targets: added.targets, regions: regions, rules: added.rules) else {
            Issue.record("expected a plan"); return
        }
        #expect(plan.operations == [.removeRule(matchType: "RULE-SET", match: "netflix")])
        let removed = try PlanApplier.apply(plan, to: added)
        #expect(!removed.candidate.contains("RULE-SET,netflix"))
        #expect(removed.items.first?.kind == .removeRule)
        if ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil {
            // The rule set itself stays defined; an unused provider is valid.
            #expect(await MihomoValidator().validate(removed.candidate).status == .passed)
        }
        #expect(throws: EditorError.self) { try LocalIntentParser.parse("删除 YouTube 规则", targets: added.targets, regions: regions, rules: added.rules) }
        // ACL4SSR-style names and numbered duplicates count as the same service.
        #expect(LocalIntentParser.serviceRules("netflix", in: ["RULE-SET,Netflix,A", "RULE-SET,netflix-2,B", "RULE-SET,netflixplus,C", "GEOSITE,netflix,D"]).map(\.payload)
                == ["Netflix", "netflix-2", "netflix"])
    }

    @Test func aiCanRemoveARuleSetByItsAnonymousLabel() throws {
        let text = SampleConfig.text.replacingOccurrences(of: "rules:", with: """
        rule-providers:
          my-company: {type: http, behavior: classical, url: 'https://rules.example.invalid/c.list', path: ./c.list}
        rules:
          - RULE-SET,my-company,DIRECT
        """)
        let doc = try ConfigDocument.parse(text)
        let anonymized = AnonymizedConfig.make(document: doc, regions: [:])
        #expect(anonymized.yaml.contains("RULE-SET,规则集1,DIRECT") && !anonymized.yaml.contains("my-company"))
        let reply = anonymized.restoringRuleSetNames(in: .plan(EditPlan(operations: [.removeRule(matchType: "RULE-SET", match: "规则集1")])))
        guard case .plan(let plan) = reply else { Issue.record("expected plan"); return }
        #expect(plan.operations == [.removeRule(matchType: "RULE-SET", match: "my-company")])
        #expect(try !PlanApplier.apply(plan, to: doc).candidate.contains("RULE-SET,my-company"))
    }
}

extension AuditFixTests {
    // D2
    @Test func ruleSetsNamedAfterTheServiceAreLikelyHits() throws {
        let rules = ["RULE-SET,netflix,日本出口"] + (try ConfigDocument.parse(SampleConfig.text).rules)
        let result = RuleMatcher.match(domain: "www.netflix.com", rules: rules)
        #expect(result.likely?.index == 0 && result.likelyTarget == "日本出口")
        #expect(!result.certain && result.target == "自动选择")
        // A rule set for another service is not a likely hit.
        #expect(RuleMatcher.match(domain: "www.youtube.com", rules: rules).likely == nil)
        #expect(RuleMatcher.match(domain: "netflix.example.com", rules: ["GEOSITE,netflix,A", "MATCH,B"]).likely?.index == 0)
        // Certain only when nothing before the hit was skipped.
        #expect(RuleMatcher.match(domain: "openai.com", rules: ["DOMAIN-SUFFIX,openai.com,DIRECT", "MATCH,X"]).certain)
    }

    // D3
    @Test func ipAddressesMatchCIDRRules() throws {
        let rules = try ConfigDocument.parse(SampleConfig.text).rules
        #expect(RuleMatcher.normalize(" 192.168.1.5 ") == "192.168.1.5")
        #expect(RuleMatcher.normalize("[2001:db8::1]") == "2001:db8::1")
        let lan = RuleMatcher.match(domain: "192.168.1.5", rules: rules)
        #expect(lan.rule == "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve" && lan.target == "DIRECT")
        // Domain rules cannot match an IP; GEOIP still needs kernel data.
        #expect(lan.skipped.map(\.rule) == ["GEOIP,CN,DIRECT,no-resolve"])
        #expect(RuleMatcher.match(domain: "10.1.2.3", rules: ["IP-CIDR,10.0.0.0/8,DIRECT", "MATCH,X"]).target == "DIRECT")
        #expect(RuleMatcher.match(domain: "11.1.2.3", rules: ["IP-CIDR,10.0.0.0/8,DIRECT", "MATCH,X"]).target == "X")
        #expect(RuleMatcher.match(domain: "2001:db8::5", rules: ["IP-CIDR6,2001:db8::/32,DIRECT", "MATCH,X"]).target == "DIRECT")
        // A domain is never resolved for no-resolve IP rules, so they are not "unknown".
        let domain = RuleMatcher.match(domain: "example.org", rules: ["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,11.0.0.0/8,DIRECT", "MATCH,X"])
        #expect(domain.skipped.map(\.rule) == ["IP-CIDR,11.0.0.0/8,DIRECT"])
    }
}

extension AuditFixTests {
    // D4
    @Test func rulePartsKeepFlagsAndLogicalPayloadsApart() {
        #expect(RuleParts.parse("GEOIP,CN,DIRECT,no-resolve") == RuleParts(type: "GEOIP", payload: "CN", target: "DIRECT", flags: ["no-resolve"]))
        #expect(RuleParts.parse("AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT")
                == RuleParts(type: "AND", payload: "((DOMAIN,a.com),(NETWORK,UDP))", target: "REJECT", flags: []))
        #expect(RuleParts.parse("MATCH,自动选择") == RuleParts(type: "MATCH", payload: nil, target: "自动选择", flags: []))
        #expect(RuleParts.parse("DOMAIN-SUFFIX,example.com") == nil)
    }
}

extension AuditFixTests {
    static func plan(_ prompt: String) throws -> AssistantReply {
        let (doc, regions) = try sample()
        return try LocalIntentParser.parse(prompt, targets: doc.targets, regions: regions, rules: doc.rules)
    }

    static func ruleSets(_ prompt: String) throws -> [String] {
        guard case .plan(let plan) = try plan(prompt) else { return [] }
        return plan.operations.compactMap { op in
            if case let .ruleSet(.catalog(source, name), _) = op { return "\(source)/\(name)" }
            if case let .route(type, match, _) = op { return "\(type),\(match)" }
            if case let .removeRule(type, match) = op { return "remove \(type),\(match)" }
            return nil
        }
    }

    // D5
    @Test func catalogServicesAndNetworksParseLocally() throws {
        let cases: [(String, [String])] = [
            ("B站直连", ["metacubex-geosite/bilibili"]), ("苹果服务直连", ["metacubex-geosite/apple"]), ("微软走美国", ["metacubex-geosite/microsoft"]),
            ("Steam 下载直连", ["metacubex-geosite/steam"]), ("X 走美国", ["metacubex-geosite/twitter"]), ("Discord 走日本", ["metacubex-geosite/discord"]),
            ("Instagram 和 Facebook 走美国", ["metacubex-geosite/facebook", "metacubex-geosite/instagram"]),
            ("国内网站直连", ["metacubex-geosite/cn"]), ("中国 IP 直连", ["metacubex-geoip/cn"]), ("局域网直连", ["metacubex-geoip/private"]),
            ("所有流媒体走新加坡", ["metacubex-geosite/category-media"]),
            ("10.0.0.0/8 直连", ["IP-CIDR,10.0.0.0/8"]), ("192.168.1.1 直连", ["IP-CIDR,192.168.1.1/32"]), ("2001:db8::/32 直连", ["IP-CIDR6,2001:db8::/32"]),
        ]
        for (prompt, expected) in cases { #expect(try Self.ruleSets(prompt) == expected, "\(prompt)") }
        // Every service the parser knows is a verified catalog name.
        for service in LocalIntentParser.services {
            let name = service.geosite.hasPrefix("geoip:") ? String(service.geosite.dropFirst(6)) : service.geosite
            let list = service.geosite.hasPrefix("geoip:") ? SystemPrompt.geoipNames : SystemPrompt.geositeNames
            #expect(list.contains(name), "\(service.geosite) is not a verified name")
        }
    }

    // D6
    @Test func quDiaoRulesIsARemoval() throws {
        #expect(try Self.ruleSets("去掉 example.com 的规则") == ["remove DOMAIN-SUFFIX,example.com"])
        #expect(try Self.ruleSets("删除 10.0.0.0/8 规则") == ["remove IP-CIDR,10.0.0.0/8"])
        // A plain negation without a region is still explained, not guessed.
        #expect(throws: EditorError.self) { try Self.plan("不要 Netflix") }
    }

    // D7
    @Test func citiesAndTraditionalNamesAreRegions() throws {
        for prompt in ["Netflix 走東京", "Netflix 走东京", "Netflix 走大阪"] { #expect(try Self.ruleSets(prompt) == ["metacubex-geosite/netflix"], "\(prompt)") }
        #expect(Region.us.instructionPattern.map("YouTube 走洛杉矶".matches) == true)
        #expect(Region.tw.instructionPattern.map("巴哈走臺灣".matches) == true)
        #expect(Region.kr.instructionPattern.map("走首尔".matches) == true)
    }

    // D12
    @Test func onlyARegionAsksWhatTraffic() throws {
        guard case let .clarification(question, options) = try Self.plan("走日本") else { Issue.record("expected a question"); return }
        #expect(question.contains("哪些流量走日本"))
        #expect(options.map(\.prompt) == ["Netflix 走日本", "YouTube 走日本", "ChatGPT 走日本"])
    }
}

extension AuditFixTests {
    // D8
    @Test func namesWithCommasDoNotBlockTheImport() throws {
        let doc = try ConfigDocument.parse("""
        proxies:
          - {name: "HK, Premium", type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
          - {name: 日本 01, type: ss, server: b.invalid, port: 1, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: 节点选择, type: select, proxies: ["HK, Premium", 日本 01]}
        rules:
          - MATCH,节点选择
        """)
        #expect(!doc.targets.contains { $0.name == "HK, Premium" })
        #expect(doc.targets.contains { $0.name == "日本 01" })
        #expect(doc.warnings.contains { $0.contains("HK, Premium") && $0.contains("规则无法引用") })
        // Editing still works and leaves the comma node alone.
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: doc.target(named: "节点选择")!.id)])
        #expect(try PlanApplier.apply(plan, to: doc).candidate.contains(#"name: "HK, Premium""#))
    }

    // D9
    @Test func largeSubscriptionsSendABoundedPayload() throws {
        var lines = ["proxies:"]
        let regions = ["香港", "日本", "美国"]
        for i in 0..<3000 { lines.append("  - {name: \"\(regions[i % 3]) \(i)\", type: ss, server: n\(i).invalid, port: 1, cipher: aes-128-gcm, password: p}") }
        lines += ["proxy-groups:", "  - {name: 香港精选, type: select, proxies: [\"香港 2997\", \"香港 3\"]}", "rules:", "  - MATCH,DIRECT"]
        let text = lines.joined(separator: "\n")
        let doc = try ConfigDocument.parse(text)
        let anonymized = AnonymizedConfig.make(document: doc, regions: Session(title: "", source: .pasted, text: text).regions(for: doc.targets))
        #expect(anonymized.yaml.utf8.count < 40_000, "payload is \(anonymized.yaml.utf8.count) bytes")
        #expect(anonymized.yaml.contains("未列出的节点") && anonymized.yaml.contains("数量: 2800"))
        // Nodes a small group names are listed even though they come late in the file.
        let label = anonymized.context.label(forName: "香港 2997")!
        #expect(anonymized.yaml.contains("name: \(label)"))
    }
}
