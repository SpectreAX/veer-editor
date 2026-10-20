import Foundation
import Testing
@testable import VeerCore

/// Exploratory probes for the 2026-10-19 test report. They print what happens instead of
/// asserting, so every case is recorded; confirmed defects become real tests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_AUDIT"] != nil))
struct AuditProbeTests {
    static func describe(_ reply: AssistantReply) -> String {
        switch reply {
        case let .clarification(question, options): return "ASK \(question.prefix(40)) [\(options.map(\.label).joined(separator: "|"))]"
        case let .outOfScope(message): return "OUT \(message.prefix(30))"
        case let .search(queries): return "SEARCH \(queries)"
        case let .plan(plan):
            return "PLAN " + plan.operations.map { op -> String in
                switch op {
                case let .route(type, match, target): return "route \(type),\(match)→\(target)"
                case let .removeRule(type, match): return "remove \(type),\(match)"
                case let .ruleSet(reference, target):
                    switch reference {
                    case let .catalog(source, name): return "ruleset \(source)/\(name)→\(target)"
                    case let .url(url, _): return "ruleset \(url)→\(target)"
                    }
                case let .group(group): return "group \(group.name) regions=\(group.regions.map(\.rawValue)) excl=\(group.excludeRegions.map(\.rawValue)) members=\(group.members)"
                }
            }.joined(separator: "; ")
        }
    }

    @Test func parserMatrix() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        let phrases = [
            "Netflix 走日本", "让 youtube 走香港", "github.com 直连", "屏蔽广告", "去掉 example.com 的规则",
            "Google 不要走香港", "telegram 走 @香港出口", "抖音直连", "B站直连", "苹果服务直连", "微软走美国",
            "ChatGPT 和 Claude 走美国", "openai.com 走美国", "*.openai.com 走美国", "10.0.0.0/8 直连", "192.168.1.1 直连",
            "Steam 下载直连", "国外 AI 服务走美国", "所有流媒体走新加坡", "Disney+ 走香港", "Spotify 走美国，Netflix 走日本，YouTube 走香港",
            "把 Netflix 改回直连", "广告拦截", "TikTok 走日本", "Twitter 走美国", "X 走美国", "Instagram 和 Facebook 走美国",
            "PayPal 走美国", "Bing 走香港", "Discord 走日本", "Reddit 走美国", "Twitch 走日本", "Amazon 走美国",
            "国内网站直连", "中国 IP 直连", "局域网直连", "走日本", "Netflix", "",
            "netflix走日本", "NETFLIX 走 JP", "Netflix 走 jp", "Netflix 走東京", "巴哈走台湾", "Netflix 走日本或者新加坡",
        ]
        for phrase in phrases {
            let result: String
            do { result = Self.describe(try LocalIntentParser.parse(phrase, targets: doc.targets, regions: regions)) }
            catch { result = "ERROR \((error as? EditorError)?.message ?? "\(error)")" }
            print("PROBE parser | \(phrase) | \(result)")
        }
    }

    @Test func awkwardConfigs() async throws {
        let cases: [(String, String)] = [
            ("comma in group name", """
            proxies:
              - {name: "HK, Premium", type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxy-groups:
              - {name: "香港, 精选", type: select, proxies: ["HK, Premium"]}
            rules:
              - MATCH,DIRECT
            """),
            ("yaml anchors and merge keys", """
            base: &base {type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxies:
              - {<<: *base, name: 日本 01}
              - {<<: *base, name: 美国 01}
            proxy-groups:
              - {name: 日本出口, type: select, proxies: [日本 01]}
            rules:
              - MATCH,日本出口
            """),
            ("no rules key", """
            proxies:
              - {name: 日本 01, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxy-groups:
              - {name: 日本出口, type: select, proxies: [日本 01]}
            """),
            ("quotes and colon in name", """
            proxies:
              - {name: "JP: 'Tokyo' \\"01\\"", type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxy-groups:
              - {name: "日本: 主力", type: select, proxies: ["JP: 'Tokyo' \\"01\\""]}
            rules:
              - MATCH,DIRECT
            """),
            ("include-all and filter groups", """
            proxies:
              - {name: 日本 01, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxy-groups:
              - {name: 日本出口, type: url-test, include-all: true, filter: "日本", url: "https://www.gstatic.com/generate_204", interval: 300}
            rules:
              - MATCH,日本出口
            """),
            ("rule with no-resolve and logical rule", """
            proxies:
              - {name: 日本 01, type: ss, server: a.invalid, port: 1, cipher: aes-128-gcm, password: p}
            proxy-groups:
              - {name: 日本出口, type: select, proxies: [日本 01]}
            rules:
              - GEOIP,CN,DIRECT,no-resolve
              - AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT
              - MATCH,日本出口
            """),
        ]
        let validator = MihomoValidator()
        for (label, text) in cases {
            do {
                let doc = try ConfigDocument.parse(text)
                let group = doc.targets.first { $0.kind == .group }
                let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: group?.id ?? doc.targets[0].id)])
                let candidate = try PlanApplier.apply(plan, to: doc).candidate
                let check = await validator.validate(candidate)
                let rules = (try? ConfigDocument.parse(candidate))?.rules ?? []
                print("PROBE config | \(label) | ok | mihomo=\(check.status) \(check.detail?.prefix(120) ?? "") | rules=\(rules.prefix(3))")
            } catch {
                print("PROBE config | \(label) | ERROR \((error as? EditorError)?.message ?? "\(error)")")
            }
        }
    }

    @Test func largeConfigTiming() throws {
        var lines = ["proxies:"]
        let regions = ["香港", "日本", "美国", "新加坡", "台湾"]
        for i in 0..<3000 { lines.append("  - {name: \"\(regions[i % 5]) \(i)\", type: ss, server: n\(i).invalid, port: 1, cipher: aes-128-gcm, password: p}") }
        lines.append("proxy-groups:")
        for region in regions {
            lines.append("  - name: \(region)节点")
            lines.append("    type: select")
            lines.append("    proxies:")
            for i in stride(from: regions.firstIndex(of: region)!, to: 3000, by: 5) { lines.append("      - \"\(region) \(i)\"") }
        }
        lines.append("rules:")
        for i in 0..<5000 { lines.append("  - DOMAIN-SUFFIX,site\(i).example,香港节点") }
        lines.append("  - MATCH,DIRECT")
        let text = lines.joined(separator: "\n")
        var start = Date()
        let doc = try ConfigDocument.parse(text)
        let parse = Date().timeIntervalSince(start)
        start = Date()
        let sessionRegions = Session(title: "", source: .pasted, text: text).regions(for: doc.targets)
        let regionTime = Date().timeIntervalSince(start)
        start = Date()
        let reply = try LocalIntentParser.parse("Netflix 走日本", targets: doc.targets, regions: sessionRegions)
        guard case .plan(let plan) = reply else { print("PROBE large | not a plan: \(Self.describe(reply))"); return }
        let candidate = try PlanApplier.apply(plan, to: doc, regions: sessionRegions).candidate
        let apply = Date().timeIntervalSince(start)
        start = Date()
        let anonymized = AnonymizedConfig.make(document: doc, regions: sessionRegions)
        let anon = Date().timeIntervalSince(start)
        start = Date()
        _ = ConfigDiff.compute(old: text, new: candidate)
        let diff = Date().timeIntervalSince(start)
        start = Date()
        _ = ProfileAnalysis.analyze(text)
        let analysis = Date().timeIntervalSince(start)
        print(String(format: "PROBE large | %d KB | parse %.2fs | regions %.2fs | plan+apply %.2fs | anonymize %.2fs (%d KB) | diff %.2fs | analysis %.2fs",
                     text.utf8.count / 1024, parse, regionTime, apply, anon, anonymized.yaml.utf8.count / 1024, diff, analysis))
    }

    @Test func everyCatalogSourcePassesMihomo() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let target = doc.target(named: "日本出口")!.id
        let references: [RuleSetReference] = [
            .catalog(source: "metacubex-geosite", name: "netflix"), .catalog(source: "metacubex-geoip", name: "netflix"),
            .catalog(source: "acl4ssr", name: "Ruleset/Google"), .catalog(source: "blackmatrix7", name: "Netflix"),
            .url("https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/youtube.yaml", behavior: "domain"),
            .url("https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Telegram.list", behavior: nil),
        ]
        let validator = MihomoValidator()
        for reference in references {
            do {
                let candidate = try PlanApplier.apply(EditPlan(operations: [.ruleSet(reference, targetId: target)]), to: doc).candidate
                let check = await validator.validate(candidate)
                print("PROBE ruleset | \(reference) | mihomo=\(check.status) \(check.detail?.prefix(120) ?? "")")
            } catch {
                print("PROBE ruleset | \(reference) | ERROR \((error as? EditorError)?.message ?? "\(error)")")
            }
        }
        // Removing the only rule a provider uses, then exporting.
        let added = try PlanApplier.apply(EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: target)]), to: doc).candidate
        let removed = try PlanApplier.apply(EditPlan(operations: [.removeRule(matchType: "RULE-SET", match: "netflix")]), to: try ConfigDocument.parse(added))
        let check = await validator.validate(removed.candidate)
        print("PROBE ruleset | remove RULE-SET netflix | items=\(removed.items.count) mihomo=\(check.status) providerLeft=\(removed.candidate.contains("netflix:"))")
    }

    @Test func ruleMatcherCases() throws {
        let rules = try ConfigDocument.parse(SampleConfig.text).rules
        for domain in ["www.netflix.com", "openai.com", "api.openai.com", "github.com", "192.168.1.5", "https://www.google.com/search?q=1", "例子.中国", "", "localhost"] {
            let result = RuleMatcher.match(domain: domain, rules: ["RULE-SET,netflix,日本出口"] + rules)
            print("PROBE matcher | \(domain) | \(result)")
        }
    }
}
