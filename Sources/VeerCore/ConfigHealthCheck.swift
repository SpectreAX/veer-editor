import Foundation
import Yams

/// One problem the health check (配置体检) can prove from the YAML alone.
public struct HealthFinding: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case shadowedRule, duplicateRule, missingTarget, missingRuleSet, missingMember, emptyGroup, unusedProvider, missingMatch, matchNotLast
    }

    /// `error`: Mihomo refuses to load the config. `warning`: rules that do nothing or a gap.
    /// `notice`: harmless clutter.
    public enum Severity: Int, Sendable, Comparable {
        case error, warning, notice
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(kind.rawValue)-\(ruleIndex.map(String.init) ?? "")-\(subject)-\(reason)" }
    public let kind: Kind
    public let severity: Severity
    public let title: String
    /// The rule, group or rule set the problem is about, as written in the config.
    public let subject: String
    /// 0-based index into `rules` when the subject is a rule.
    public let ruleIndex: Int?
    public let reason: String
    /// Operations that fix it without changing where any connection goes; empty when no fix is safe.
    public let fix: [EditPlan.Operation]
    public let fixTitle: String?
    /// What the user can do when there is no safe fix.
    public let hint: String?
}

/// Scans a draft for problems that are certain from the YAML: rules an earlier rule always takes
/// over, exact duplicates, references to missing exits or rule sets, empty groups, unused rule
/// sets and a missing or misplaced MATCH. Runtime facts (DNS answers, node health, what a rule
/// set downloads) are never guessed.
///
/// Mihomo keeps matching after a hit when the hit's exit turns out to be PASS, or is a connection
/// over UDP to an exit without UDP. So an earlier rule only certainly takes over when its exit is
/// DIRECT / REJECT / REJECT-DROP, or the same exit as the later rule. Other exits are certain for
/// TCP only, and such findings carry no fix.
public enum ConfigHealthCheck {
    static let deciding: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP"]
    static let domainTypes: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"]
    static let cidrTypes: Set<String> = ["IP-CIDR", "IP-CIDR6"]

    public static func run(_ text: String) -> [HealthFinding] {
        guard let root = (try? compose(yaml: text))??.mapping else { return [] }
        func strings(_ node: Node?) -> [String] { node?.sequence?.compactMap(\.string) ?? [] }

        let proxies = root["proxies"]?.sequence?.compactMap(\.mapping) ?? []
        let groups = (root["proxy-groups"]?.sequence?.compactMap(\.mapping) ?? []).filter { $0["name"]?.string != nil }
        var names = ConfigDocument.builtinPolicies
        for item in proxies + groups { if let name = item["name"]?.string { names.insert(name) } }
        let groupMembers = Dictionary(groups.map { ($0["name"]!.string!, strings($0["proxies"])) }, uniquingKeysWith: { first, _ in first })
        let proxyProviders = Set(root["proxy-providers"]?.mapping?.compactMap { $0.key.string } ?? [])
        let ruleProviders = root["rule-providers"]?.mapping?.compactMap { $0.key.string } ?? []
        // Indices match ConfigDocument.rules; lines that do not parse are skipped, not renumbered.
        let lines = root["rules"]?.sequence?.map { $0.string ?? "" } ?? []
        let rules = lines.map(RuleParts.parse)
        let subRules = (root["sub-rules"]?.mapping ?? [:]).flatMap { strings($0.value) }

        var findings: [HealthFinding] = []

        // References that do not exist: Mihomo refuses to load the config.
        for (index, rule) in rules.enumerated() {
            guard let rule else { continue }
            if rule.type != "SUB-RULE", !names.contains(rule.target) {
                findings.append(HealthFinding(kind: .missingTarget, severity: .error, title: "规则指向不存在的出口", subject: lines[index], ruleIndex: index,
                                              reason: "配置里没有名为“\(rule.target)”的策略组或节点（名称区分大小写），Mihomo 会拒绝加载这个配置。",
                                              fix: [], fixTitle: nil, hint: "把出口改成已有的策略组，或删除这条规则（可以直接告诉 AI）。"))
            }
            for set in ruleSetReferences(rule) where !ruleProviders.contains(set) {
                findings.append(HealthFinding(kind: .missingRuleSet, severity: .error, title: "规则引用了不存在的规则集", subject: lines[index], ruleIndex: index,
                                              reason: "rule-providers 里没有“\(set)”，Mihomo 会拒绝加载这个配置。",
                                              fix: [], fixTitle: nil, hint: "用 /ruleset 添加这个规则集，或删除这条规则。"))
            }
        }
        for group in groups {
            let name = group["name"]!.string!
            let members = strings(group["proxies"]), uses = strings(group["use"])
            for member in members where !names.contains(member) {
                findings.append(HealthFinding(kind: .missingMember, severity: .error, title: "策略组引用了不存在的成员", subject: name, ruleIndex: nil,
                                              reason: "“\(name)”的 proxies 里有“\(member)”，但配置里没有这个节点或策略组，Mihomo 会拒绝加载这个配置。",
                                              fix: [], fixTitle: nil, hint: nil))
            }
            for use in uses where !proxyProviders.contains(use) {
                findings.append(HealthFinding(kind: .missingMember, severity: .error, title: "策略组引用了不存在的节点订阅", subject: name, ruleIndex: nil,
                                              reason: "“\(name)”的 use 里有“\(use)”，但 proxy-providers 里没有它，Mihomo 会拒绝加载这个配置。",
                                              fix: [], fixTitle: nil, hint: nil))
            }
            let includesAll = ["include-all", "include-all-proxies", "include-all-providers"].contains { group[$0]?.bool == true }
            if members.isEmpty && uses.isEmpty && !includesAll {
                findings.append(HealthFinding(kind: .emptyGroup, severity: .error, title: "策略组没有成员", subject: name, ruleIndex: nil,
                                              reason: "“\(name)”没有 proxies、use，也没有 include-all，Mihomo 会拒绝加载这个配置。",
                                              fix: [], fixTitle: nil, hint: "告诉 AI 这个策略组应该包含哪些节点。"))
            }
        }

        // Rules that can never decide anything.
        let firstMatch = rules.firstIndex { $0?.type == "MATCH" }
        /// Whether an earlier rule hitting with `exit` always ends matching for TCP: exits that
        /// exist and cannot lead to PASS.
        func endsTCP(_ exit: String) -> Bool {
            guard names.contains(exit), exit != "PASS" else { return false }
            var seen = Set<String>(), queue = [exit]
            while let next = queue.popLast() {
                guard seen.insert(next).inserted else { continue }
                for member in groupMembers[next] ?? [] {
                    if member == "PASS" { return false }
                    queue.append(member)
                }
            }
            return true
        }
        for j in rules.indices where firstMatch.map({ j < $0 }) ?? true {
            guard let later = rules[j] else { continue }
            var certain: Int?, tcpOnly: Int?, duplicate: Int?
            for i in 0..<j {
                guard let earlier = rules[i], covers(earlier, later) else { continue }
                if key(earlier) == key(later) && earlier.target == later.target { duplicate = i; break }
                if deciding.contains(earlier.target) || (earlier.target == later.target && names.contains(earlier.target)) {
                    certain = certain ?? i
                } else if tcpOnly == nil, endsTCP(earlier.target) {
                    tcpOnly = i
                }
            }
            let remove = [EditPlan.Operation.removeRuleAt(index: j, rule: lines[j])]
            if let i = duplicate {
                findings.append(HealthFinding(kind: .duplicateRule, severity: .notice, title: "重复规则", subject: lines[j], ruleIndex: j,
                                              reason: "与第 \(i + 1) 条完全相同，Mihomo 只会用到前一条。",
                                              fix: remove, fixTitle: "删除重复的这条", hint: nil))
            } else if let i = certain {
                let why = rules[i]!.target == later.target ? "而且出口相同" : "而且它的出口 \(rules[i]!.target) 一定会接住连接"
                findings.append(HealthFinding(kind: .shadowedRule, severity: .warning, title: "规则永远不会命中", subject: lines[j], ruleIndex: j,
                                              reason: "第 \(i + 1) 条 \(lines[i]) 已经覆盖它，\(why)。删除它不会改变任何连接的去向。",
                                              fix: remove, fixTitle: "删除这条规则", hint: nil))
            } else if let i = tcpOnly {
                findings.append(HealthFinding(kind: .shadowedRule, severity: .warning, title: "TCP 连接永远不会命中这条规则", subject: lines[j], ruleIndex: j,
                                              reason: "第 \(i + 1) 条 \(lines[i]) 已经覆盖它，连接会先走“\(rules[i]!.target)”。只有 UDP 连接在“\(rules[i]!.target)”当前的出口不支持 UDP 时，才会继续往下匹配到这条。",
                                              fix: [], fixTitle: nil, hint: "如果想让它生效，把它移到第 \(i + 1) 条之前（可以直接告诉 AI）。"))
            }
        }

        if let m = firstMatch {
            let matchExit = rules[m]!.target
            let after = Array(rules.indices.dropFirst(m + 1))
            if !after.isEmpty {
                // Dead for every connection when MATCH always decides or the rule has the same exit.
                let dead = after.filter { deciding.contains(matchExit) || (rules[$0]?.target == matchExit && names.contains(matchExit)) }
                let tcpNote = dead.count == after.count ? "" : "其中 \(after.count - dead.count) 条只对 TCP 确定：UDP 连接在“\(matchExit)”当前的出口不支持 UDP 时，仍会继续往下匹配。"
                findings.append(HealthFinding(kind: .matchNotLast, severity: .warning, title: "MATCH 后面还有规则", subject: lines[m], ruleIndex: m,
                                              reason: "MATCH 会接住所有走到它的连接，后面的 \(after.count) 条规则（第 \(after.count == 1 ? "\(m + 2)" : "\(m + 2)–\(lines.count)") 条）永远不会命中。\(tcpNote)",
                                              fix: dead.map { .removeRuleAt(index: $0, rule: lines[$0]) },
                                              fixTitle: dead.isEmpty ? nil : dead.count == after.count ? "删除后面 \(dead.count) 条规则" : "删除一定不会命中的 \(dead.count) 条",
                                              hint: dead.isEmpty ? "如果想让它们生效，把它们移到 MATCH 之前（可以直接告诉 AI）。" : nil))
            }
        } else if !lines.isEmpty {
            findings.append(HealthFinding(kind: .missingMatch, severity: .warning, title: "没有 MATCH 兜底规则", subject: "rules", ruleIndex: nil,
                                          reason: "没有命中任何规则的连接会直连（DIRECT）。",
                                          fix: [], fixTitle: nil, hint: "如果想让它们走代理，告诉 AI 例如“其他流量走自动选择”。"))
        }

        // Rule sets nothing uses. Any other mention of the name (DNS policy, TUN route sets…)
        // counts as a use, so this never flags a set that is used outside `rules`.
        var used = Set(rules.compactMap { $0 }.flatMap(ruleSetReferences))
        used.formUnion(subRules.compactMap(RuleParts.parse).flatMap(ruleSetReferences))
        let elsewhere = scalars(in: root, skipping: ["rule-providers", "rules", "sub-rules"])
        for key in ruleProviders where !used.contains(key) && !elsewhere.contains(where: { $0.contains(key) }) {
            findings.append(HealthFinding(kind: .unusedProvider, severity: .notice, title: "规则集没有被使用", subject: key, ruleIndex: nil,
                                          reason: "没有规则（包括逻辑规则和 sub-rules）或其他设置引用“\(key)”，删除它不会改变任何连接的去向。",
                                          fix: [.removeProvider(key: key)], fixTitle: "删除这个规则集", hint: nil))
        }

        return findings.enumerated().sorted { a, b in
            a.element.severity != b.element.severity ? a.element.severity < b.element.severity : a.offset < b.offset
        }.map(\.element)
    }

    /// Rule-set names a rule reads, including inside logical rules (`AND,((RULE-SET,x),…)`).
    static func ruleSetReferences(_ rule: RuleParts) -> [String] {
        if rule.type == "RULE-SET" { return rule.payload.map { [$0] } ?? [] }
        guard let payload = rule.payload, payload.contains("(") else { return [] }
        let regex = try! NSRegularExpression(pattern: #"(?i)RULE-SET\s*,\s*([^,()]+?)\s*(?:[,)])"#)
        return regex.matches(in: payload, range: NSRange(payload.startIndex..., in: payload)).compactMap {
            Range($0.range(at: 1), in: payload).map { String(payload[$0]) }
        }
    }

    /// Type and payload; domains ignore case.
    static func matcher(_ rule: RuleParts) -> String {
        let payload = domainTypes.contains(rule.type) ? rule.payload?.lowercased() : rule.payload
        return "\(rule.type),\(payload ?? "")"
    }

    /// What makes two rules the same apart from their exit: matcher and flags.
    static func key(_ rule: RuleParts) -> String {
        ([matcher(rule)] + rule.flags.map { $0.lowercased() }).joined(separator: ",")
    }

    /// Whether `earlier` matches every connection `later` matches. Only decided for identical
    /// matchers, domain rules and CIDRs; anything else is never assumed to cover.
    static func covers(_ earlier: RuleParts, _ later: RuleParts) -> Bool {
        guard later.type != "MATCH", earlier.type != "MATCH" else { return false }
        // Options other than no-resolve change what a rule looks at (src…): they must agree.
        let earlierFlags = Set(earlier.flags.map { $0.lowercased() }), laterFlags = Set(later.flags.map { $0.lowercased() })
        guard earlierFlags.subtracting(["no-resolve"]) == laterFlags.subtracting(["no-resolve"]),
              !earlierFlags.contains("no-resolve") || laterFlags.contains("no-resolve") else { return false }
        if matcher(earlier) == matcher(later) { return true }
        guard let a = earlier.payload?.lowercased(), let b = later.payload?.lowercased() else { return false }
        if domainTypes.contains(earlier.type) && domainTypes.contains(later.type) {
            guard isPlainDomain(a), isPlainDomain(b) else { return false }
            switch (earlier.type, later.type) {
            case ("DOMAIN-SUFFIX", "DOMAIN"), ("DOMAIN-SUFFIX", "DOMAIN-SUFFIX"): return b == a || b.hasSuffix("." + a)
            // Every domain a suffix or exact rule matches contains its payload, so a keyword inside it matches too.
            case ("DOMAIN-KEYWORD", _): return b.contains(a)
            default: return false
            }
        }
        if cidrTypes.contains(earlier.type) && cidrTypes.contains(later.type) {
            guard let outer = IPAddress.network(a), let inner = IPAddress.network(b) else { return false }
            return outer.address.bytes.count == inner.address.bytes.count && outer.prefix <= inner.prefix && outer.contains(inner.address)
        }
        return false
    }

    static func isPlainDomain(_ value: String) -> Bool {
        value.matches(#"^[a-z0-9-]+(?:\.[a-z0-9-]+)*$"#)
    }

    /// Every scalar (keys and values) outside the skipped top-level keys.
    static func scalars(in root: Node.Mapping, skipping: Set<String>) -> [String] {
        var out: [String] = []
        func walk(_ node: Node) {
            switch node {
            case .scalar(let scalar): out.append(scalar.string)
            case .sequence(let sequence): sequence.forEach(walk)
            case .mapping(let mapping): for (key, value) in mapping { walk(key); walk(value) }
            case .alias: break
            }
        }
        for (key, value) in root where !skipping.contains(key.string ?? "") { walk(key); walk(value) }
        return out
    }
}
