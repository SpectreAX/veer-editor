import Foundation

/// Finds the first rule a domain hits, using only rule types decidable without kernel data.
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
    }

    public static func normalize(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let parsed = url.host, host.contains("://") { host = parsed }
        host = host.split(separator: "/").first.map(String.init) ?? host
        if host.hasSuffix(".") { host.removeLast() }
        guard host.matches(#"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*[a-z0-9-]+$"#), host.count <= 253 else { return nil }
        return host
    }

    public static func match(domain: String, rules: [String]) -> Result {
        var skipped: [Skipped] = []
        for (index, rule) in rules.enumerated() {
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first?.uppercased() else { continue }
            if type == "MATCH" { return Result(index: index, rule: rule, target: parts.count > 1 ? parts[1] : nil, skipped: skipped) }
            guard parts.count >= 3 else { continue }
            let value = parts[1].lowercased()
            let hit: Bool
            switch type {
            case "DOMAIN": hit = domain == value
            case "DOMAIN-SUFFIX": hit = domain == value || domain.hasSuffix("." + value)
            case "DOMAIN-KEYWORD": hit = domain.contains(value)
            default:
                skipped.append(Skipped(index: index, rule: rule))
                continue
            }
            if hit { return Result(index: index, rule: rule, target: parts[2], skipped: skipped) }
        }
        return Result(index: nil, rule: nil, target: nil, skipped: skipped)
    }
}
