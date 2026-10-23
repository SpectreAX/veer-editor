import Foundation
import Testing
@testable import VeerCore

/// 配置体检: each kind of finding, no false positives, and fixes that go through PlanApplier.
struct HealthCheckTests {
    static func config(groups: String = "", rules: [String], providers: String = "", extra: String = "") -> String {
        """
        mode: rule
        proxies:
          - {name: A, type: ss, server: a.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
          - {name: B, type: ss, server: b.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: 代理, type: select, proxies: [A, B]}
          - {name: 可跳过, type: select, proxies: [A, PASS]}
        \(groups)
        \(providers)
        \(extra)
        rules:
        \(rules.map { "  - \($0)" }.joined(separator: "\n"))

        """
    }

    static func kinds(_ findings: [HealthFinding]) -> [HealthFinding.Kind] { findings.map(\.kind) }

    @Test func sampleConfigHasNoFindings() {
        #expect(ConfigHealthCheck.run(SampleConfig.text).isEmpty)
    }

    @Test func noFalsePositivesOnOrdinaryRules() {
        // Narrow before broad, distinct matchers, IP rules that only look alike, logical rules.
        let text = Self.config(rules: [
            "DOMAIN,mail.google.com,DIRECT", "DOMAIN-SUFFIX,google.com,代理", "DOMAIN-KEYWORD,googleapis,代理",
            "DOMAIN-SUFFIX,cn,DIRECT", "DOMAIN-SUFFIX,xn,代理",
            "IP-CIDR,10.0.0.0/16,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,代理,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "IP-CIDR,192.168.1.0/24,代理",
            "GEOIP,CN,DIRECT", "GEOIP,CN,代理,src", "SRC-IP-CIDR,10.0.0.0/8,DIRECT",
            "AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT", "DOMAIN,a.com,代理", "MATCH,代理",
        ])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func shadowedRuleWithDecidingExitHasAFix() throws {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,DIRECT", "DOMAIN,mail.google.com,代理", "DOMAIN-KEYWORD,ads,REJECT",
                                       "DOMAIN-SUFFIX,ads.example.com,代理", "IP-CIDR,10.0.0.0/8,DIRECT", "IP-CIDR,10.1.0.0/16,代理,no-resolve", "MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.shadowedRule, .shadowedRule, .shadowedRule])
        #expect(findings.map(\.ruleIndex) == [1, 3, 5])
        #expect(findings.allSatisfy { $0.fixTitle != nil && !$0.fix.isEmpty })
        #expect(findings[0].reason.contains("第 1 条"))
    }

    @Test func shadowedRuleWithSameExitIsCertain() {
        let findings = ConfigHealthCheck.run(Self.config(rules: ["DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,代理", "MATCH,DIRECT"]))
        #expect(Self.kinds(findings) == [.shadowedRule])
        #expect(findings[0].title == "规则永远不会命中")
        #expect(findings[0].reason.contains("出口相同"))
    }

    @Test func shadowedByAGroupIsOnlyCertainForTCP() {
        // UDP to an exit without UDP keeps matching, so no fix is offered.
        let findings = ConfigHealthCheck.run(Self.config(rules: ["DOMAIN-SUFFIX,google.com,代理", "DOMAIN,mail.google.com,DIRECT", "MATCH,DIRECT"]))
        #expect(Self.kinds(findings) == [.shadowedRule])
        #expect(findings[0].title.contains("TCP"))
        #expect(findings[0].fix.isEmpty)
        #expect(findings[0].hint != nil)
    }

    @Test func exitsThatCanPassNeverShadow() {
        // A group that may be set to PASS, PASS itself, or a missing exit lets matching continue.
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,可跳过", "DOMAIN,mail.google.com,DIRECT",
                                       "DOMAIN-SUFFIX,youtube.com,PASS", "DOMAIN,m.youtube.com,DIRECT", "MATCH,DIRECT"])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func noResolveOnTheEarlierRuleDoesNotCover() {
        // The earlier rule never resolves domains; the later one does, so it still matches domains.
        let text = Self.config(rules: ["IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.1.0.0/16,代理", "MATCH,代理"])
        #expect(ConfigHealthCheck.run(text).isEmpty)
    }

    @Test func exactDuplicates() throws {
        let text = Self.config(rules: ["DOMAIN-SUFFIX,github.com,代理", "GEOIP,CN,DIRECT,no-resolve", "domain-suffix,GitHub.com,代理", "GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.duplicateRule, .duplicateRule])
        #expect(findings.map(\.ruleIndex) == [2, 3])
        // Removing one copy keeps the other, even though both share the same prefix.
        let doc = try ConfigDocument.parse(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings.flatMap(\.fix)), to: doc)
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN-SUFFIX,github.com,代理", "GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"])
        #expect(result.items.map(\.kind) == [.removeRule, .removeRule])
    }

    @Test func missingReferences() {
        let text = """
        proxies:
          - {name: A, type: ss, server: a.example.invalid, port: 1, cipher: aes-128-gcm, password: x}
        proxy-groups:
          - {name: G, type: select, proxies: [A, 不存在的节点], use: [没有的订阅]}
        rules:
          - DOMAIN,a.com,不存在的组
          - DOMAIN,b.com,direct
          - RULE-SET,netflix,G
          - AND,((RULE-SET,ads),(NETWORK,UDP)),REJECT
          - MATCH,G

        """
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.missingTarget, .missingTarget, .missingRuleSet, .missingRuleSet, .missingMember, .missingMember])
        #expect(findings.allSatisfy { $0.severity == .error && $0.fix.isEmpty })
        #expect(findings[3].reason.contains("“ads”"))
    }

    @Test func emptyGroups() {
        let text = Self.config(groups: """
          - {name: 空组, type: select}
          - {name: 空列表, type: url-test, proxies: []}
          - {name: 全部, type: select, include-all: true}
        """, rules: ["MATCH,代理"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.emptyGroup, .emptyGroup])
        #expect(findings.map(\.subject) == ["空组", "空列表"])
    }

    @Test func unusedRuleProvidersAndTheirRemoval() throws {
        let providers = """
        rule-providers:
          # 广告
          ads:
            type: http
            behavior: domain
            url: https://example.invalid/ads.mrs
            path: ./ads.mrs
          netflix: {type: http, behavior: domain, url: "https://example.invalid/netflix.mrs", path: ./netflix.mrs}
          nested: {type: http, behavior: domain, url: "https://example.invalid/nested.mrs", path: ./nested.mrs}
          dns-only: {type: http, behavior: domain, url: "https://example.invalid/dns.mrs", path: ./dns.mrs}
          sub: {type: http, behavior: domain, url: "https://example.invalid/sub.mrs", path: ./sub.mrs}
        """
        let extra = """
        dns:
          nameserver-policy:
            "rule-set:dns-only": [223.5.5.5]
        sub-rules:
          s1:
            - RULE-SET,sub,DIRECT
        """
        let text = Self.config(rules: ["RULE-SET,netflix,代理", "OR,((RULE-SET,nested),(DOMAIN,x.com)),DIRECT", "MATCH,代理"], providers: providers, extra: extra)
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.unusedProvider])
        #expect(findings[0].subject == "ads")
        #expect(findings[0].fix == [.removeProvider(key: "ads")])

        let doc = try ConfigDocument.parse(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings[0].fix), to: doc)
        #expect(result.items.map(\.kind) == [.removeProvider])
        let after = try ConfigDocument.parse(result.candidate)
        #expect(after.providers.map(\.key).sorted() == ["dns-only", "nested", "netflix", "sub"])
        #expect(!result.candidate.contains("广告") && !result.candidate.contains("ads.mrs"))
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty)

        // A rule set a rule still uses is never removed.
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeProvider(key: "netflix")]), to: doc) }
    }

    @Test func removingTheLastProviderLeavesAnEmptyMapping() throws {
        let text = Self.config(rules: ["MATCH,代理"], providers: """
        rule-providers:
          ads: {type: http, behavior: domain, url: "https://example.invalid/ads.mrs", path: ./ads.mrs}
        """)
        let result = try PlanApplier.apply(EditPlan(operations: [.removeProvider(key: "ads")]), to: try ConfigDocument.parse(text))
        #expect(result.candidate.contains("rule-providers: {}"))
        #expect(try ConfigDocument.parse(result.candidate).providers.isEmpty)
    }

    @Test func missingMatch() {
        let findings = ConfigHealthCheck.run(Self.config(rules: ["DOMAIN,a.com,代理"]))
        #expect(Self.kinds(findings) == [.missingMatch])
        #expect(findings[0].fix.isEmpty)
    }

    @Test func matchThatIsNotLast() throws {
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "MATCH,DIRECT", "DOMAIN,b.com,代理", "GEOIP,CN,DIRECT"])
        let findings = ConfigHealthCheck.run(text)
        #expect(Self.kinds(findings) == [.matchNotLast])
        #expect(findings[0].ruleIndex == 1)
        #expect(findings[0].fix.count == 2)
        let result = try PlanApplier.apply(EditPlan(operations: findings[0].fix), to: try ConfigDocument.parse(text))
        #expect(try ConfigDocument.parse(result.candidate).rules == ["DOMAIN,a.com,代理", "MATCH,DIRECT"])

        // MATCH to a group: only rules with the same exit are certainly dead.
        let partial = ConfigHealthCheck.run(Self.config(rules: ["MATCH,代理", "DOMAIN,b.com,DIRECT", "DOMAIN,c.com,代理"]))
        #expect(Self.kinds(partial) == [.matchNotLast])
        #expect(partial[0].fix == [.removeRuleAt(index: 2, rule: "DOMAIN,c.com,代理")])
        #expect(partial[0].reason.contains("只对 TCP 确定"))
    }

    @Test func staleIndexIsRefused() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeRuleAt(index: 0, rule: "DOMAIN,changed.com,DIRECT")]), to: doc) }
        #expect(throws: EditorError.self) { try PlanApplier.apply(EditPlan(operations: [.removeRuleAt(index: 99, rule: "MATCH,自动选择")]), to: doc) }
    }

    @Test func errorsComeFirst() {
        let text = Self.config(rules: ["DOMAIN,a.com,代理", "DOMAIN,a.com,代理", "DOMAIN,b.com,没有"])
        #expect(ConfigHealthCheck.run(text).map(\.severity) == [.error, .warning, .notice])
    }

    @Test func fixedConfigsPassMihomo() async throws {
        guard ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil else { return }
        let text = Self.config(rules: ["DOMAIN-SUFFIX,google.com,DIRECT", "DOMAIN,mail.google.com,代理", "DOMAIN,x.com,代理", "DOMAIN,x.com,代理", "MATCH,代理", "DOMAIN,y.com,代理"],
                               providers: "rule-providers:\n  ads: {type: http, behavior: domain, format: mrs, url: \"https://example.invalid/ads.mrs\", path: ./ads.mrs}")
        let findings = ConfigHealthCheck.run(text)
        let result = try PlanApplier.apply(EditPlan(operations: findings.flatMap(\.fix)), to: try ConfigDocument.parse(text))
        #expect(ConfigHealthCheck.run(result.candidate).isEmpty)
        #expect(await MihomoValidator().validate(result.candidate).status == .passed)
    }
}
