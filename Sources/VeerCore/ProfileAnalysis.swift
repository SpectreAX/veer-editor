import Foundation
import Yams

/// Read-only structural summary of a Mihomo profile, shown before import. Mirrors the Android
/// `ProfileAnalyzer` so both clients count the same way. Names are carried as data only.
public struct ProfileAnalysis: Sendable, Equatable {
    public struct Count: Sendable, Equatable, Hashable {
        public let label: String
        public let count: Int
        public init(label: String, count: Int) { self.label = label; self.count = count }
    }

    public struct Provider: Sendable, Equatable {
        public let name: String
        /// http, file, inline; nil when omitted.
        public let type: String?
    }

    public enum MemberKind: String, Sendable { case group, proxy, builtin, missing }

    public struct Member: Sendable, Equatable, Hashable {
        public let name: String
        public let kind: MemberKind
        public init(name: String, kind: MemberKind) { self.name = name; self.kind = kind }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let type: String
        public let members: [Member]
        /// Providers pulled in with `use:`.
        public let providers: [String]
        public let includesAll: Bool
        /// Other groups and rules that point at this group.
        public let referenceCount: Int
    }

    public struct Flow: Sendable, Equatable, Identifiable {
        public var id: String { target }
        public let target: String
        public let ruleCount: Int
        public let ruleTypes: [Count]
    }

    public let sizeBytes: Int
    public let proxyCount: Int
    public let proxyProviderCount: Int
    public let groupCount: Int
    public let ruleCount: Int
    public let ruleProviderCount: Int
    /// Largest first; labels are display-normalized (SS, VLESS…).
    public let protocols: [Count]
    public let ruleTargets: [Count]
    public let ruleTypes: [Count]
    public let groupTypes: [Count]
    public let builtInProxies: Int
    public let providers: [Provider]
    /// Document order.
    public let groups: [Group]
    public let flows: [Flow]

    public var isEmpty: Bool { proxyCount == 0 && proxyProviderCount == 0 && groupCount == 0 && ruleCount == 0 }

    static let protocolLabels = ["ss": "SS", "shadowsocks": "SS", "ssr": "SSR", "vmess": "VMess", "vless": "VLESS", "trojan": "Trojan",
                                 "anytls": "AnyTLS", "hysteria": "Hysteria", "hysteria2": "Hysteria2", "tuic": "TUIC", "wireguard": "WireGuard",
                                 "socks5": "SOCKS5", "http": "HTTP", "snell": "Snell", "ssh": "SSH", "mieru": "Mieru", "direct": "DIRECT",
                                 "reject": "REJECT", "dns": "DNS"]
    static let groupTypeLabels = ["select": "Select", "url-test": "URLTest", "fallback": "Fallback", "load-balance": "LoadBalance", "relay": "Relay"]

    public static func analyze(_ text: String) -> ProfileAnalysis? {
        guard let root = (try? compose(yaml: text))??.mapping else { return nil }
        func strings(_ node: Node?) -> [String] { node?.sequence?.compactMap(\.string) ?? [] }

        let proxies = root["proxies"]?.sequence?.compactMap(\.mapping) ?? []
        let proxyNames = Set(proxies.compactMap { $0["name"]?.string })
        let providers = (root["proxy-providers"]?.mapping ?? [:]).compactMap { key, value in
            key.string.map { Provider(name: $0, type: value.mapping?["type"]?.string) }
        }
        let rawGroups = (root["proxy-groups"]?.sequence?.compactMap(\.mapping) ?? []).filter { $0["name"]?.string != nil }
        let groupNames = Set(rawGroups.compactMap { $0["name"]?.string })
        let rules = (root["rules"]?.sequence?.compactMap(\.string) ?? []).compactMap(parseRule)

        var references: [String: Int] = [:]
        for group in rawGroups { for member in Set(strings(group["proxies"])) { references[member, default: 0] += 1 } }
        for rule in rules { references[rule.target, default: 0] += 1 }

        let groups = rawGroups.map { group -> Group in
            let name = group["name"]!.string!
            return Group(
                name: name,
                type: label(group["type"]?.string, in: groupTypeLabels, uppercaseFallback: false),
                members: strings(group["proxies"]).map { member in
                    Member(name: member, kind: groupNames.contains(member) ? .group
                        : proxyNames.contains(member) ? .proxy
                        : ConfigDocument.builtinPolicies.contains(member.uppercased()) ? .builtin : .missing)
                },
                providers: strings(group["use"]),
                includesAll: ["include-all", "include-all-proxies", "include-all-providers"].contains { group[$0]?.bool == true },
                referenceCount: references[name] ?? 0
            )
        }

        let flows = Dictionary(grouping: rules, by: \.target)
            .map { Flow(target: $0.key, ruleCount: $0.value.count, ruleTypes: counts($0.value.map(\.type))) }
            .sorted { $0.ruleCount != $1.ruleCount ? $0.ruleCount > $1.ruleCount : $0.target < $1.target }

        return ProfileAnalysis(
            sizeBytes: text.utf8.count,
            proxyCount: proxies.count,
            proxyProviderCount: providers.count,
            groupCount: rawGroups.count,
            ruleCount: rules.count,
            ruleProviderCount: root["rule-providers"]?.mapping?.count ?? 0,
            protocols: counts(proxies.map { label($0["type"]?.string, in: protocolLabels, uppercaseFallback: true) }),
            ruleTargets: flows.map { Count(label: $0.target, count: $0.ruleCount) },
            ruleTypes: counts(rules.map(\.type)),
            groupTypes: counts(groups.map(\.type)),
            builtInProxies: proxies.count,
            providers: providers,
            groups: groups,
            flows: flows
        )
    }

    struct Rule { let type: String; let target: String }

    /// Splits on top-level commas so logical rules like `AND,((DOMAIN,a.com),(NETWORK,UDP)),Proxy`
    /// keep their payload. MATCH has its target second; every other rule third.
    static func parseRule(_ line: String) -> Rule? {
        var parts: [String] = [], current = "", depth = 0
        for char in line.trimmingCharacters(in: .whitespaces) {
            switch char {
            case "(": depth += 1; current.append(char)
            case ")": depth = max(0, depth - 1); current.append(char)
            case "," where depth == 0: parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(char)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        guard let first = parts.first, !first.isEmpty else { return nil }
        let type = first.uppercased()
        let index = type == "MATCH" ? 1 : 2
        guard parts.count > index, !parts[index].isEmpty else { return nil }
        return Rule(type: type, target: parts[index])
    }

    static func label(_ raw: String?, in table: [String: String], uppercaseFallback: Bool) -> String {
        let key = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !key.isEmpty else { return "?" }
        return table[key] ?? (uppercaseFallback ? key.uppercased() : key)
    }

    static func counts(_ labels: [String]) -> [Count] {
        Dictionary(grouping: labels, by: { $0 }).map { Count(label: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

extension Array where Element == ProfileAnalysis.Count {
    /// First `limit` entries plus the summed remainder and how many labels it hides.
    public func top(_ limit: Int) -> (top: [ProfileAnalysis.Count], otherCount: Int, otherLabels: Int) {
        guard count > limit else { return (self, 0, 0) }
        let rest = dropFirst(limit)
        return (Array(prefix(limit)), rest.reduce(0) { $0 + $1.count }, rest.count)
    }
}

/// Whole-number percentage: "62%", "<1%" for small non-zero shares.
public func percentLabel(_ count: Int, of total: Int) -> String {
    guard total > 0, count > 0 else { return "0%" }
    let percent = Double(count) * 100 / Double(total)
    return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
}
