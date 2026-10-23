import Foundation
import Testing
@testable import VeerCore

struct RuleMatcherGeoTests {
    static let geosite = try! GeoSiteDatabase(data: GeoFixture.geosite([
        ("netflix", [(2, "netflix.com", []), (0, "nflx", [])]),
        ("bilibili", [(2, "bilibili.com", [])]),
    ]))
    static let geoip = try! GeoIPDatabase(data: GeoFixture.geoip([
        ("cn", [([1, 0, 1, 0], 24)]), ("telegram", [([91, 108, 4, 0], 22)]), ("private", [([10, 0, 0, 0], 8)]),
    ]))
    static let providers = [
        ConfigDocument.Provider(key: "netflix", url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs", path: nil),
        ConfigDocument.Provider(key: "tg", url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs", path: nil),
        ConfigDocument.Provider(key: "acl", url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/Netflix.list", path: nil),
    ]
    static let rules = [
        "RULE-SET,netflix,日本出口", "GEOSITE,bilibili,DIRECT", "RULE-SET,tg,香港出口,no-resolve",
        "GEOIP,CN,DIRECT", "IP-CIDR,9.9.9.0/24,美国出口", "MATCH,自动选择",
    ]

    static func context(addresses: [String] = []) -> RuleMatcher.Context {
        RuleMatcher.Context(geosite: geosite, geoip: geoip, addresses: addresses, providers: providers)
    }

    @Test func ruleSetsAndGeositeAreDecidedLocally() {
        let netflix = RuleMatcher.match(domain: "www.netflix.com", rules: Self.rules, context: Self.context())
        #expect(netflix.index == 0 && netflix.target == "日本出口" && netflix.certain && netflix.byGeodata && netflix.likely == nil)
        let bilibili = RuleMatcher.match(domain: "www.bilibili.com", rules: Self.rules, context: Self.context())
        #expect(bilibili.index == 1 && bilibili.certain && bilibili.byGeodata)
        // Keyword entries count for GEOSITE rules but are not in rule-set files.
        let keyword = "nflxvideo.example"
        #expect(RuleMatcher.match(domain: keyword, rules: ["GEOSITE,netflix,日本出口", "MATCH,DIRECT"], context: Self.context()).index == 0)
        #expect(RuleMatcher.match(domain: keyword, rules: ["RULE-SET,netflix,日本出口", "MATCH,DIRECT"], context: Self.context()).index == 1)
        // A rule set Veer cannot read stays undecided.
        let unknown = RuleMatcher.match(domain: "www.netflix.com", rules: ["RULE-SET,acl,代理", "MATCH,DIRECT"], context: Self.context())
        #expect(unknown.skipped.map(\.index) == [0] && !unknown.certain && !unknown.needsAddress)
    }

    @Test func ipRulesUseTheResolvedAddress() {
        // A cn address: the telegram set has no-resolve (skipped for domains), GEOIP,CN decides.
        let cn = RuleMatcher.match(domain: "www.example.cn", rules: Self.rules, context: Self.context(addresses: ["1.0.1.5"]))
        #expect(cn.index == 3 && cn.target == "DIRECT" && cn.certain && cn.byGeodata && cn.address == "1.0.1.5")
        let elsewhere = RuleMatcher.match(domain: "www.example.org", rules: Self.rules, context: Self.context(addresses: ["9.9.9.9"]))
        #expect(elsewhere.index == 4 && elsewhere.certain && !elsewhere.byGeodata)
        // Not resolved yet: IP rules wait for the address.
        let pending = RuleMatcher.match(domain: "www.example.cn", rules: Self.rules, context: Self.context())
        #expect(pending.needsAddress && pending.index == 5 && !pending.certain && pending.skipped.map(\.index) == [3, 4])
        // An IP input needs no resolving; no-resolve does not apply to it.
        let telegram = RuleMatcher.match(domain: "91.108.5.1", rules: Self.rules, context: Self.context())
        #expect(telegram.index == 2 && telegram.certain && telegram.byGeodata && telegram.address == nil)
        #expect(RuleMatcher.match(domain: "10.1.2.3", rules: ["GEOIP,LAN,DIRECT", "MATCH,代理"], context: Self.context()).index == 0)
    }

    @Test func withoutGeodataNothingChanges() {
        let plain = RuleMatcher.match(domain: "www.netflix.com", rules: Self.rules)
        #expect(plain.likely?.index == 0 && !plain.byGeodata && plain.index == 5)
        let set = MetaCubeXSet(url: "https://x/geo/geosite/category-ai-!cn.mrs")
        #expect(set?.kind == "geosite" && set?.name == "category-ai-!cn")
        #expect(MetaCubeXSet(url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Ruleset/Netflix.list") == nil)
        // GEOIP with no-resolve can never match a domain, so it is not listed as undecided.
        #expect(RuleMatcher.match(domain: "www.example.cn", rules: ["GEOIP,CN,DIRECT,no-resolve", "MATCH,代理"]).certain)
    }
}
