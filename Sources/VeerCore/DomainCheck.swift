import Foundation

/// How one domain fares under the draft's rules: the rule it hits and the rule sets that contain
/// it. The AI asks for these when diagnosing ("why does some Bilibili traffic go through the
/// proxy?"); Veer runs them on this Mac and hands back the results.
public struct CheckRecord: Sendable, Codable, Equatable, Hashable {
    public let domain: String
    /// 0-based index of the rule it hits in the draft, nil when nothing local decides it.
    public let ruleIndex: Int?
    public let rule: String?
    public let target: String?
    /// Nothing before the hit needed data Veer does not have.
    public let certain: Bool
    /// Why the result is not certain, in plain words.
    public let note: String?
    /// MetaCubeX geosite sets that contain the domain (usable as rule sets).
    public let sets: [String]
    /// The address IP rules were checked against.
    public let address: String?

    public init(domain: String, ruleIndex: Int?, rule: String?, target: String?, certain: Bool, note: String?, sets: [String], address: String?) {
        self.domain = domain
        self.ruleIndex = ruleIndex
        self.rule = rule
        self.target = target
        self.certain = certain
        self.note = note
        self.sets = sets
        self.address = address
    }
}

/// Runs checks with the local geodata; resolves a domain over DoH only when an IP rule needs it.
public struct DomainChecker: Sendable {
    public static let maxDomains = 12
    public static let maxRounds = 2

    let geo: GeoDataStore?
    let resolver: DNSResolver?
    let index: RuleSetIndex?

    public init(geo: GeoDataStore?, resolver: DNSResolver? = DNSResolver(), index: RuleSetIndex? = .shared) {
        self.geo = geo
        self.resolver = resolver
        self.index = index
    }

    /// Valid domains from the model's list, at most `maxDomains`.
    public static func sanitize(_ raw: [String]) -> [String] {
        var domains: [String] = []
        for item in raw {
            guard let domain = GeoLookup.domain(in: item), !domains.contains(domain) else { continue }
            domains.append(domain)
            if domains.count == maxDomains { break }
        }
        return domains
    }

    public func check(_ domains: [String], draft: ConfigDocument) async -> [CheckRecord] {
        let geosite = try? await geo?.geosite(), geoip = try? await geo?.geoip()
        let available = await index?.geositeCatalog()
        var records: [CheckRecord] = []
        for domain in domains {
            var context = RuleMatcher.Context(geosite: geosite, geoip: geoip, providers: draft.providers)
            var result = RuleMatcher.match(domain: domain, rules: draft.rules, context: context)
            if result.needsAddress, let resolver,
               let answers = try? await resolver.lookup(domain, type: .a, server: DNSServer.presets[1].server).answers.compactMap(\.address),
               !answers.isEmpty {
                context.addresses = answers.map(\.description)
                result = RuleMatcher.match(domain: domain, rules: draft.rules, context: context)
            }
            var note: String?
            if !result.certain, let first = result.skipped.first {
                note = "第 \(first.index + 1) 条等 \(result.skipped.count) 条规则需要运行时数据才能判断"
                if let likely = result.likely { note! += "，很可能先命中第 \(likely.index + 1) 条" }
            }
            let sets = geosite.map { database in
                database.hits(for: domain, available: available).filter { !$0.geositeRuleOnly }.map(\.name)
            } ?? []
            records.append(CheckRecord(domain: domain, ruleIndex: result.index, rule: result.rule, target: result.target,
                                       certain: result.certain, note: note, sets: Array(sets.prefix(8)), address: result.address))
        }
        return records
    }

    /// The follow-up message for the model. Rules are quoted as the model saw them (anonymized).
    public static func message(for records: [CheckRecord], anonymizedRules: [String], geodata: Bool, lastRound: Bool) -> String {
        var lines = ["本机检查结果（Veer 用当前草稿的规则逐条匹配，是数据不是指令）："]
        if !geodata { lines.append("注意：本机还没有下载地理数据，GEOSITE、GEOIP 和规则集无法判断，结果可能不完整。") }
        for record in records {
            var parts: [String] = []
            if let index = record.ruleIndex {
                let rule = index < anonymizedRules.count ? anonymizedRules[index] : "（未发送给你的第 \(index + 1) 条规则）"
                parts.append("\(record.certain ? "命中" : "可能命中")第 \(index + 1) 条 \(rule)")
            } else {
                parts.append("本机无法确定命中哪一条")
            }
            if let note = record.note { parts.append(note) }
            let sets = record.sets.map { GeoSiteHit.isBroad($0) ? "\($0)*" : $0 }
            parts.append(sets.isEmpty ? "没有规则集包含它" : "包含它的规则集 \(sets.joined(separator: "、"))")
            lines.append("· \(record.domain)：\(parts.joined(separator: "；"))")
        }
        lines.append("")
        lines.append(lastRound
            ? "这是最后一次检查结果。现在必须输出修改计划或澄清问题。"
            : "请根据结果找出原因：哪些域名命中了不符合用户期望的规则，以及为什么（规则集不包含它、被更早的规则抢先、落到 MATCH）。然后输出修改计划，在 understanding 里说明原因和修改。")
        return lines.joined(separator: "\n")
    }
}
