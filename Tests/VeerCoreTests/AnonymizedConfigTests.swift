import Foundation
import Testing
import Yams
@testable import VeerCore

struct AnonymizedConfigTests {
    let source = """
    mixed-port: 7890
    mode: rule
    dns: {enable: true, nameserver: ['https://dns.secret-resolver.invalid/dns-query']}
    external-controller: 127.0.0.1:9090
    secret: controller-secret
    proxy-providers:
      airport: {type: http, url: 'https://sub.my-airport.invalid/api?token=abc123', path: ./a.yaml}
    proxies:
      - {name: "🇯🇵 东京 IEPL 01", type: vless, server: jp.my-airport.invalid, port: 443, uuid: 11111111-2222-3333-4444-555555555555, servername: sni.my-airport.invalid, reality-opts: {public-key: PUBLIC-KEY-VALUE, short-id: ab12}}
      - {name: "🇺🇸 洛杉矶 02", type: trojan, server: 203.0.113.9, port: 8443, password: trojan-password}
    proxy-groups:
      - {name: "🚀 我的机场", type: select, use: [airport], proxies: ["🇯🇵 东京 IEPL 01", "🇺🇸 洛杉矶 02", DIRECT]}
      - {name: 日本自动, type: url-test, url: 'https://probe.my-airport.invalid/204', interval: 300, proxies: ["🇯🇵 东京 IEPL 01"]}
    rule-providers:
      netflix: {type: http, behavior: domain, format: mrs, url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/netflix.mrs', path: ./n.mrs}
      my-company: {type: http, behavior: classical, url: 'https://rules.corp.invalid/list?key=xyz', path: ./c.list}
    rules:
      - RULE-SET,netflix,日本自动
      - RULE-SET,my-company,DIRECT
      - DOMAIN-SUFFIX,intranet.corp.invalid,DIRECT
      - IP-CIDR,10.20.0.0/16,DIRECT,no-resolve
      - GEOSITE,cn,DIRECT
      - AND,((DOMAIN,a.invalid),(NETWORK,UDP)),REJECT
      - MATCH,🚀 我的机场
    """

    func make(literals: Bool = false) throws -> AnonymizedConfig {
        let doc = try ConfigDocument.parse(source)
        let regions = Session(title: "", source: .pasted, text: source).regions(for: doc.targets)
        return AnonymizedConfig.make(document: doc, regions: regions, shareRuleLiterals: literals)
    }

    /// A value the user typed is sent in the instruction anyway; masking it in the rules only hides
    /// which rule they mean ("把 google 的规则删掉" against DOMAIN-KEYWORD,google).
    @Test func valuesTypedInTheInstructionStayReadable() throws {
        let doc = try ConfigDocument.parse(source)
        let regions = Session(title: "", source: .pasted, text: source).regions(for: doc.targets)
        let typed = AnonymizedConfig.make(document: doc, regions: regions, instruction: "去掉 intranet.corp.invalid 的规则")
        #expect(typed.rules.contains("DOMAIN-SUFFIX,intranet.corp.invalid,DIRECT"))
        #expect(typed.rules.contains("IP-CIDR,<IP1>,DIRECT,no-resolve"))
        #expect(typed.yaml.contains("用户指令里写出的值保持原样"))
        #expect(typed.comparison.sections.first { $0.title == "规则中的具体值" }?.rows.first?.sent == "intranet.corp.invalid")
        // Only whole tokens: "corp" inside another word, or a value the user did not type, stays masked.
        let other = AnonymizedConfig.make(document: doc, regions: regions, instruction: "mycorp.invalid 直连")
        #expect(other.rules.contains("DOMAIN-SUFFIX,<域名1>,DIRECT"))
        #expect(AnonymizedConfig.typedInInstruction("google", "把 google 的规则删掉"))
        #expect(AnonymizedConfig.typedInInstruction("google", "google.com 直连"))
        #expect(!AnonymizedConfig.typedInInstruction("google", "mygoogle 直连"))
        #expect(!AnonymizedConfig.typedInInstruction("0.0.0/8", "10.0.0.0/8 直连"))
        #expect(!AnonymizedConfig.typedInInstruction("jp", "所有 .jp 域名走日本"))
    }

    @Test func comparisonPairsEachOriginalWithWhatWasSent() throws {
        let sections = try make().comparison.sections
        func rows(_ title: String) -> [String] {
            sections.first { $0.title == title }?.rows.map { "\($0.original) → \($0.sent)" } ?? []
        }
        #expect(sections.map(\.title) == ["节点", "策略组", "代理集", "规则集", "规则", "规则中的具体值", "未发送的配置"])
        #expect(rows("节点") == ["🇯🇵 东京 IEPL 01 → 节点1（日本）", "🇺🇸 洛杉矶 02 → 节点2（美国）"])
        #expect(rows("策略组") == ["🚀 我的机场 · select → 策略组1 · select", "日本自动 · url-test → 策略组2（日本） · url-test"])
        #expect(rows("代理集") == ["airport → 代理集1"])
        #expect(rows("规则集") == ["netflix → netflix", "my-company → 规则集1"])
        #expect(rows("规则").first == "RULE-SET,netflix,日本自动 → RULE-SET,netflix,策略组2（日本）")
        #expect(rows("规则").count == 7)
        #expect(rows("规则中的具体值") == ["intranet.corp.invalid → <域名1>", "10.20.0.0/16 → <IP2>"])
        #expect(rows("未发送的配置") == ["mixed-port → 未发送", "dns → 未发送", "external-controller → 未发送", "secret → 未发送"])
        // Row ids are unique across sections so one lazy list can show them all.
        let ids = sections.flatMap { $0.rows.map(\.id) }
        #expect(Set(ids).count == ids.count)
        let shared = try make(literals: true).comparison.sections
        #expect(!shared.contains { $0.title == "规则中的具体值" })
    }

    @Test func findsTheDraftARequestWasMadeFrom() throws {
        // Imported one version, wrote another (the one sent), then wrote again.
        var session = Session(title: "a.yaml", source: .pasted, text: source.replacingOccurrences(of: "GEOSITE,cn,DIRECT", with: "GEOSITE,google,DIRECT"))
        let doc = try ConfigDocument.parse(source)
        let regions = session.regions(for: doc.targets)
        let request = EditorEngine.Request(prompt: "Netflix 走日本", draft: doc, regions: regions, useAI: true, settings: AISettings(), apiKey: "k")
        let payload = EditorEngine.payload(for: request)
        #expect(payload.sourceDigest == AIRequestPayload.digest(source) && payload.shareRuleLiterals == false)
        // The draft has since changed by a write: the old text is on the undo stack.
        session.undoStack.append(source)
        session.draftText = source + "\n  - DOMAIN,extra.invalid,DIRECT\n"
        let lookup: (ConfigDocument) -> [String: Region] = { session.regions(for: $0.targets) }
        #expect(session.sourceDraft(for: payload, regions: lookup) == source)
        let rebuilt = try #require(PayloadComparison.rebuild(for: payload, source: source, regions: lookup))
        let expected = try make().comparison
        #expect(rebuilt.exact && rebuilt.comparison == expected)
        // Payloads saved before digests existed are matched by their YAML.
        var legacy = payload
        legacy.sourceDigest = nil
        legacy.shareRuleLiterals = nil
        #expect(session.sourceDraft(for: legacy, regions: lookup) == source)
        // A draft that no longer exists anywhere in the session is reported as missing.
        session.undoStack = []
        #expect(session.sourceDraft(for: payload, regions: lookup) == nil)
    }

    @Test func removesEverythingIdentifying() throws {
        let yaml = try make().yaml
        for secret in ["my-airport", "token=abc123", "11111111-2222", "PUBLIC-KEY-VALUE", "203.0.113.9", "trojan-password", "8443",
                       "东京", "洛杉矶", "IEPL", "我的机场", "日本自动", "🇯🇵", "🚀", "secret-resolver", "controller-secret", "9090", "7890",
                       "probe.", "corp.invalid", "my-company", "10.20.0.0", "vless", "trojan", "rule_provider", "airport"] {
            #expect(!yaml.contains(secret), "leaked \(secret)")
        }
    }

    @Test func keepsStructureForTheModel() throws {
        let anonymized = try make()
        let root = try #require(try Yams.load(yaml: anonymized.yaml) as? [String: Any])
        #expect(root["mode"] as? String == "rule")
        #expect(Set(root.keys) == ["mode", "内置出口", "proxies", "proxy-groups", "rule-providers", "rules"])
        let proxies = try #require(root["proxies"] as? [[String: String]])
        #expect(proxies.map { $0["name"] } == ["节点1（日本）", "节点2（美国）"])
        let groups = try #require(root["proxy-groups"] as? [[String: Any]])
        #expect(groups[0]["name"] as? String == "策略组1" && groups[0]["type"] as? String == "select")
        #expect(groups[0]["proxies"] as? [String] == ["节点1（日本）", "节点2（美国）", "DIRECT"])
        #expect(groups[0]["use"] as? [String] == ["代理集1"])
        #expect(groups[1]["name"] as? String == "策略组2（日本）" && groups[1]["type"] as? String == "url-test")
        let rules = try #require(root["rules"] as? [String])
        #expect(rules == ["RULE-SET,netflix,策略组2（日本）", "RULE-SET,规则集1,DIRECT", "DOMAIN-SUFFIX,<域名1>,DIRECT",
                          "IP-CIDR,<IP2>,DIRECT,no-resolve", "GEOSITE,cn,DIRECT", "AND,<逻辑条件>,REJECT", "MATCH,策略组1"])
        let builtins = try #require(root["内置出口"] as? [[String: String]])
        #expect(builtins.map { $0["name"] } == ["DIRECT", "REJECT"] && builtins.allSatisfy { $0["id"]?.hasPrefix("target-") == true })
        // ids match what plans must use.
        #expect(groups[1]["id"] as? String == (try ConfigDocument.parse(source)).target(named: "日本自动")?.id)
    }

    @Test func literalsOnlyWhenTheUserOptsIn() throws {
        let yaml = try make(literals: true).yaml
        #expect(yaml.contains("DOMAIN-SUFFIX,intranet.corp.invalid,DIRECT") && yaml.contains("10.20.0.0/16"))
        #expect(!yaml.contains("token=abc123") && !yaml.contains("my-airport"))
    }

    @Test func staysCompactForLargeSubscriptions() throws {
        let regions = ["日本", "美国", "香港", "新加坡"]
        var yaml = "proxies:\n"
        for i in 0..<400 { yaml += "  - {name: '\(regions[i % 4]) \(i)', type: ss, server: n\(i).invalid, port: 1, cipher: aes-128-gcm, password: p}\n" }
        yaml += "proxy-groups:\n"
        for g in 0..<120 { yaml += "  - {name: G\(g), type: select, proxies: [\((0..<400).map { "'\(regions[$0 % 4]) \($0)'" }.joined(separator: ", "))]}\n" }
        yaml += "rules:\n" + (0..<500).map { "  - DOMAIN-SUFFIX,d\($0).invalid,G\($0 % 120)\n" }.joined()
        let doc = try ConfigDocument.parse(yaml)
        let output = AnonymizedConfig.make(document: doc, regions: Session(title: "", source: .pasted, text: yaml).regions(for: doc.targets)).yaml
        #expect(output.utf8.count < 60_000, "\(output.utf8.count) bytes")
        #expect(output.contains("# 另有 200 条规则未列出"))
    }

    @Test func summarizesLargeGroups() throws {
        var yaml = "proxies:\n"
        for i in 0..<60 { yaml += "  - {name: '\(i % 2 == 0 ? "日本" : "香港") \(i)', type: ss, server: n\(i).invalid, port: 1, cipher: aes-128-gcm, password: p}\n" }
        yaml += "proxy-groups:\n  - {name: All, type: select, proxies: [\((0..<60).map { "'\($0 % 2 == 0 ? "日本" : "香港") \($0)'" }.joined(separator: ", ")), DIRECT]}\nrules:\n  - MATCH,All\n"
        let doc = try ConfigDocument.parse(yaml)
        let regions = Session(title: "", source: .pasted, text: yaml).regions(for: doc.targets)
        let output = AnonymizedConfig.make(document: doc, regions: regions).yaml
        let root = try #require(try Yams.load(yaml: output) as? [String: Any])
        let group = try #require((root["proxy-groups"] as? [[String: Any]])?.first)
        let summary = try #require(group["proxies"] as? [String: Any])
        #expect(summary["节点数"] as? Int == 60)
        #expect((summary["按地区"] as? [String: Int]) == ["日本": 30, "香港": 30])
        #expect(summary["其他成员"] as? [String] == ["DIRECT"])
    }
}
