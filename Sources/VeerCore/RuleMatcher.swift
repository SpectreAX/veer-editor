import Foundation

/// Finds the first rule a domain or IP hits, using only what can be decided without kernel data.
public enum RuleMatcher {
    public struct Skipped: Sendable, Hashable {
        public let index: Int
        public let rule: String
    }

    public struct Result: Sendable, Hashable {
        /// 0-based index into `rules`, nil when nothing local matched.
        public let index: Int?
        public let rule: String?
        public let target: String?
        /// Rules before the hit that need GEO/IP/provider data and may match first.
        public let skipped: [Skipped]
        /// The first skipped rule that probably matches: a rule set or GEOSITE named after the
        /// service in the domain (RULE-SET,netflix for www.netflix.com).
        public var likely: Skipped? = nil
        public var likelyTarget: String? = nil

        /// The hit is certain only when nothing before it had to be skipped.
        public var certain: Bool { index != nil && skipped.isEmpty }
    }

    public static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let parsed = url.host, host.contains("://") { host = parsed }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if IPAddress(host) != nil { return host }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if host.hasSuffix(".") { host.removeLast() }
        guard host.matches(#"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*[a-z0-9-]+$"#), host.count <= 253 else { return nil }
        return host
    }

    public static func match(domain: String, rules: [String]) -> Result {
        let ip = IPAddress(domain)
        var skipped: [Skipped] = []
        var likely: (Skipped, String)?
        func finish(_ index: Int?, _ rule: String?, _ target: String?) -> Result {
            var result = Result(index: index, rule: rule, target: target, skipped: skipped)
            result.likely = likely?.0
            result.likelyTarget = likely?.1
            return result
        }
        for (index, rule) in rules.enumerated() {
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first?.uppercased() else { continue }
            if type == "MATCH" { return finish(index, rule, parts.count > 1 ? parts[1] : nil) }
            guard parts.count >= 3 else { continue }
            let value = parts[1].lowercased()
            let noResolve = parts.dropFirst(3).contains { $0.lowercased() == "no-resolve" }
            // Domain and GEOSITE rules never match a bare IP destination.
            if ip != nil, ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "GEOSITE"].contains(type) { continue }
            let hit: Bool
            switch type {
            case "DOMAIN": hit = domain == value
            case "DOMAIN-SUFFIX": hit = domain == value || domain.hasSuffix("." + value)
            case "DOMAIN-KEYWORD": hit = domain.contains(value)
            case "IP-CIDR", "IP-CIDR6":
                if let ip {
                    hit = IPAddress.network(value)?.contains(ip) ?? false
                } else if noResolve {
                    continue   // With no-resolve, a domain is never resolved for this rule.
                } else {
                    skipped.append(Skipped(index: index, rule: rule))
                    continue
                }
            default:
                let skip = Skipped(index: index, rule: rule)
                skipped.append(skip)
                if likely == nil, ip == nil, ["RULE-SET", "GEOSITE"].contains(type), namesService(value, in: domain) { likely = (skip, parts[2]) }
                continue
            }
            if hit { return finish(index, rule, parts[2]) }
        }
        return finish(nil, nil, nil)
    }

    /// "netflix" for www.netflix.com or netflix.net; ignores numbering ("netflix-2") and case.
    static func namesService(_ name: String, in domain: String) -> Bool {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }.trimmingCharacters(in: .decimalDigits)
        guard key.count >= 3 else { return false }
        return domain.split(separator: ".").dropLast().contains { $0.lowercased().filter { $0.isLetter || $0.isNumber } == key }
    }
}

/// IPv4 or IPv6 address as bytes, for CIDR containment.
struct IPAddress: Hashable {
    let bytes: [UInt8]

    init?(_ text: String) {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    struct Network {
        let address: IPAddress
        let prefix: Int

        func contains(_ ip: IPAddress) -> Bool {
            guard ip.bytes.count == address.bytes.count else { return false }
            var remaining = prefix
            for (a, b) in zip(ip.bytes, address.bytes) {
                guard remaining > 0 else { return true }
                let bits = min(8, remaining)
                let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                if a & mask != b & mask { return false }
                remaining -= bits
            }
            return true
        }
    }

    static func network(_ cidr: String) -> Network? {
        let parts = cidr.split(separator: "/")
        guard let address = IPAddress(String(parts[0])) else { return nil }
        let maxPrefix = address.bytes.count * 8
        let prefix = parts.count > 1 ? Int(parts[1]) ?? -1 : maxPrefix
        guard (0...maxPrefix).contains(prefix) else { return nil }
        return Network(address: address, prefix: prefix)
    }
}

/// One rule split into its parts, respecting parentheses in logical rules
/// (`AND,((DOMAIN,a.com),(NETWORK,UDP)),REJECT`) and keeping trailing flags apart.
public struct RuleParts: Sendable, Equatable {
    public let type: String
    /// nil for MATCH.
    public let payload: String?
    public let target: String
    /// Extra options after the target, such as `no-resolve` or `src`.
    public let flags: [String]

    public static func parse(_ line: String) -> RuleParts? {
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
        if type == "MATCH" {
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            return RuleParts(type: type, payload: nil, target: parts[1], flags: Array(parts.dropFirst(2)))
        }
        guard parts.count > 2, !parts[2].isEmpty else { return nil }
        return RuleParts(type: type, payload: parts[1], target: parts[2], flags: Array(parts.dropFirst(3)))
    }
}
