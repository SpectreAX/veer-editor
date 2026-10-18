import Foundation

/// Rule sets Veer may add as Mihomo `rule-providers`. The model names a source and a file
/// stem; Veer builds the URL itself, so a model can never inject an arbitrary address.
public enum RuleSetCatalog {
    public struct Spec: Sendable, Hashable {
        public let url: String
        public let behavior: String
        public let format: String
        public let key: String
        /// Human label, e.g. "MetaCubeX geosite/netflix".
        public let sourceLabel: String
        /// Service name for the UI, e.g. "Netflix".
        public let serviceName: String
    }

    struct Source: Sendable {
        let behavior: String
        let format: String
        let label: String
        let namePattern: String
        let url: @Sendable (String) -> String
        let key: @Sendable (String) -> String
    }

    static let sources: [String: Source] = [
        "metacubex-geosite": Source(behavior: "domain", format: "mrs", label: "MetaCubeX geosite", namePattern: #"^[a-z0-9@!._-]{1,64}$"#,
                                    url: { "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/\($0).mrs" }, key: { $0 }),
        "metacubex-geoip": Source(behavior: "ipcidr", format: "mrs", label: "MetaCubeX geoip", namePattern: #"^[a-z0-9._-]{1,64}$"#,
                                  url: { "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/\($0).mrs" }, key: { "\($0)-ip" }),
        "acl4ssr": Source(behavior: "classical", format: "text", label: "ACL4SSR", namePattern: #"^(Ruleset/)?[A-Za-z0-9_-]{1,64}$"#,
                          url: { "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/\($0).list" }, key: { String($0.split(separator: "/").last ?? "") }),
        "blackmatrix7": Source(behavior: "classical", format: "text", label: "blackmatrix7", namePattern: #"^[A-Za-z0-9_-]{1,64}$"#,
                               url: { "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/\($0)/\($0).list" }, key: { $0 }),
    ]

    public static var findHelp: String { SystemPrompt.findRuleSetHelp }

    static let serviceNames: [String: String] = [
        "netflix": "Netflix", "openai": "ChatGPT", "youtube": "YouTube", "google": "Google", "telegram": "Telegram",
        "github": "GitHub", "spotify": "Spotify", "tiktok": "TikTok", "twitter": "X (Twitter)", "facebook": "Facebook",
        "instagram": "Instagram", "apple": "Apple", "microsoft": "Microsoft", "bilibili": "哔哩哔哩", "steam": "Steam",
        "disney": "Disney+", "bahamut": "巴哈姆特", "cn": "中国大陆网站", "category-ads-all": "广告", "private": "局域网",
        "anthropic": "Claude", "discord": "Discord", "amazon": "Amazon", "cloudflare": "Cloudflare",
        "category-ai-!cn": "国外 AI 服务", "category-ai-chat-!cn": "国外 AI 对话", "category-ai-cn": "国内 AI 服务",
        "google-gemini": "Gemini", "perplexity": "Perplexity", "xai": "Grok", "groq": "Groq", "poe": "Poe", "category-games": "游戏",
    ]

    public static func displayName(for name: String) -> String {
        let stem = String(name.split(separator: "/").last ?? Substring(name))
        return serviceNames[stem.lowercased()] ?? stem
    }

    public static func spec(for reference: RuleSetReference) throws -> Spec {
        var spec: Spec
        switch reference {
        case let .catalog(sourceID, name):
            guard let source = sources[sourceID] else { throw EditorError("不支持的规则集来源：\(sourceID.prefix(40))") }
            guard name.range(of: source.namePattern, options: .regularExpression) != nil else {
                throw EditorError("规则集名称无效：\(name.prefix(64))")
            }
            spec = Spec(url: source.url(name), behavior: source.behavior, format: source.format, key: source.key(name),
                        sourceLabel: "\(source.label)/\(name)", serviceName: displayName(for: name))
        case let .url(raw, declared):
            spec = try fromURL(raw, declared: declared)
        }
        if spec.format == "mrs" && spec.behavior == "classical" {
            throw EditorError("mrs 格式只支持域名或 IP 段规则集，不支持混合（classical）规则。")
        }
        let key = String(spec.key.replacingOccurrences(of: #"[^A-Za-z0-9@!._-]"#, with: "-", options: .regularExpression).prefix(64))
        return Spec(url: spec.url, behavior: spec.behavior, format: spec.format, key: key, sourceLabel: spec.sourceLabel, serviceName: spec.serviceName)
    }

    static func fromURL(_ raw: String, declared: String?) throws -> Spec {
        guard let url = URLComponents(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, let host = url.host,
              ["raw.githubusercontent.com", "cdn.jsdelivr.net"].contains(host) else {
            throw EditorError("规则集地址须为 raw.githubusercontent.com 或 cdn.jsdelivr.net 上的 HTTPS 文件。")
        }
        let path = url.path
        let fileName = (path as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension.lowercased()
        let formats = ["mrs": "mrs", "list": "text", "txt": "text", "yaml": "yaml", "yml": "yaml"]
        guard let format = formats[ext] else { throw EditorError("规则集文件须为 .mrs、.list、.txt 或 .yaml。") }
        let behavior: String? = path.contains("/geosite/") ? "domain" : path.contains("/geoip/") ? "ipcidr" : format == "text" ? "classical" : declared
        guard let behavior, ["domain", "ipcidr", "classical"].contains(behavior) else {
            throw EditorError("无法从地址判断规则集类型，请说明它是域名、IP 段还是混合规则。")
        }
        let stem = ((fileName.removingPercentEncoding ?? fileName) as NSString).deletingPathExtension
        let key = behavior == "ipcidr" && path.contains("/geoip/") ? "\(stem)-ip" : stem
        return Spec(url: raw, behavior: behavior, format: format, key: key, sourceLabel: "自定义地址 \(host)", serviceName: displayName(for: stem))
    }

    static let extensions = ["mrs": "mrs", "text": "list", "yaml": "yaml"]

    /// Reuses a provider with the same URL, otherwise picks a free key.
    static func place(_ spec: Spec, existing: [String: String?]) -> (key: String, reused: Bool, provider: [(String, String)]?) {
        if let match = existing.first(where: { $0.value == spec.url }) { return (match.key, true, nil) }
        var key = spec.key
        var n = 1
        while existing.keys.contains(key) {
            key = n == 1 ? "\(spec.key)-veer" : "\(spec.key)-veer\(n)"
            n += 1
        }
        let provider: [(String, String)] = [
            ("type", "http"), ("behavior", spec.behavior), ("format", spec.format), ("url", spec.url),
            ("path", "./rule_provider/\(key).\(extensions[spec.format] ?? "list")"), ("interval", "86400"),
        ]
        return (key, false, provider)
    }
}

/// Checks new rule-set URLs. 404 rejects the plan; network failure only marks it unverified.
public enum RuleSetVerification: String, Sendable, Codable, Hashable {
    case verified, unverified, missing, reused
}

public protocol RuleSetVerifying: Sendable {
    func verify(_ urls: [String]) async -> [String: RuleSetVerification]
}

public struct NetworkRuleSetVerifier: RuleSetVerifying {
    public init() {}
    public func verify(_ urls: [String]) async -> [String: RuleSetVerification] {
        await withTaskGroup(of: (String, RuleSetVerification).self) { group in
            for url in Set(urls) {
                group.addTask {
                    guard let target = URL(string: url) else { return (url, .missing) }
                    var request = URLRequest(url: target, timeoutInterval: 8)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        return (url, (200..<300).contains(status) ? .verified : status == 404 ? .missing : .unverified)
                    } catch {
                        return (url, .unverified)
                    }
                }
            }
            var results: [String: RuleSetVerification] = [:]
            for await (url, status) in group { results[url] = status }
            return results
        }
    }
}
