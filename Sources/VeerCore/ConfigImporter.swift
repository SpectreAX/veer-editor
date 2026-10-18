import Foundation
import Yams

/// Recognizes what an imported file or subscription contains and turns it into a Mihomo
/// configuration. Detection order follows Mihomo's own provider parser: YAML first, then
/// Base64-or-plain share links.
public enum ConfigImporter {
    public enum Format: String, Sendable, Codable {
        case mihomoYAML, proxyListYAML, base64Links, plainLinks

        public var label: String {
            switch self {
            case .mihomoYAML: "Mihomo / Clash 配置"
            case .proxyListYAML: "YAML 节点列表"
            case .base64Links: "Base64 订阅（分享链接）"
            case .plainLinks: "分享链接列表"
            }
        }
    }

    public struct Result: Sendable {
        public let text: String
        public let format: Format
        public let nodeCount: Int
        public let skipped: [String: Int]

        /// Explains a conversion to the user; nil when the input was already a full config.
        public var note: String? {
            guard format != .mihomoYAML else { return nil }
            var text = "已识别为\(format.label)，共 \(nodeCount) 个节点。Veer 生成了一份基础 Mihomo 配置：“节点选择”“自动选择”和按地区分组的策略组，规则只有 MATCH 兜底，可以接着用对话添加分流。"
            if !skipped.isEmpty {
                let detail = skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) 个" }.joined(separator: "、")
                text += "无法转换、已跳过：\(detail)。"
            }
            return text + "导出的是生成后的完整配置，不是原始订阅内容。"
        }
    }

    public static let selectGroup = "节点选择"
    public static let autoGroup = "自动选择"

    public static func normalize(_ raw: String) throws -> Result {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorError("内容是空的。请导入 Mihomo YAML 配置、Base64 订阅或分享链接列表。") }
        guard trimmed.utf8.count <= ConfigDocument.maxBytes else { throw EditorError("内容超过 2 MB，请先拆分后再导入。") }
        if trimmed.range(of: #"^\s*(<!doctype html|<html)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw EditorError("这是一个网页，不是配置。订阅链接可能已失效、需要登录，或返回了错误页面。")
        }

        if let yaml = try yamlResult(text) { return yaml }

        if let decoded = ShareLinkParser.base64String(trimmed), decoded.contains("://") || decoded.contains(":") {
            if decoded.contains("://") { return try fromLinks(decoded, format: .base64Links) }
            if let yaml = try? yamlResult(decoded) { return yaml }
        }
        if trimmed.contains("://") { return try fromLinks(trimmed, format: .plainLinks) }
        throw EditorError("无法识别这份内容。Veer 支持 Mihomo / Clash YAML 配置、YAML 节点列表、Base64 订阅和分享链接列表（ss、ssr、vmess、vless、trojan、hysteria、hysteria2、tuic、socks5、http、anytls）。")
    }

    /// nil when the text is not YAML that Veer can use (a scalar, or unparsable).
    static func yamlResult(_ text: String) throws -> Result? {
        guard let node = try? compose(yaml: text) else { return nil }
        if let mapping = node.mapping {
            let keys = Set(mapping.keys.compactMap(\.string))
            if keys.contains("outbounds") && (keys.contains("inbounds") || keys.contains("route")) {
                throw EditorError("这是 sing-box 配置。Veer 目前只编辑 Mihomo 配置，请导入 Mihomo / Clash 格式的订阅。")
            }
            if keys == ["proxies"], let list = mapping["proxies"]?.sequence {
                return try fromProxyNodes(Array(list), format: .proxyListYAML)
            }
            return Result(text: text, format: .mihomoYAML, nodeCount: mapping["proxies"]?.sequence?.count ?? 0, skipped: [:])
        }
        if let sequence = node.sequence, !sequence.isEmpty,
           sequence.allSatisfy({ $0.mapping?["name"] != nil && $0.mapping?["type"] != nil }) {
            return try fromProxyNodes(Array(sequence), format: .proxyListYAML)
        }
        return nil
    }

    static func fromLinks(_ text: String, format: Format) throws -> Result {
        let parsed = ShareLinkParser.parse(text)
        guard !parsed.proxies.isEmpty else {
            let schemes = parsed.skipped.keys.sorted().joined(separator: "、")
            throw EditorError(schemes.isEmpty ? "没有找到可以识别的分享链接。" : "没有可以转换的节点：\(schemes) 链接格式无法识别或不受支持。")
        }
        let proxies = parsed.proxies.map { proxy in proxy.map { ($0.0, $0.1) } }
        return try build(proxies: proxies.map { .map($0) }, format: format, skipped: parsed.skipped)
    }

    static func fromProxyNodes(_ nodes: [Node], format: Format) throws -> Result {
        try build(proxies: nodes.compactMap(value(from:)), format: format, skipped: [:])
    }

    static func value(from node: Node) -> YAMLValue? {
        switch node {
        case .scalar(let scalar):
            // Keep quoted strings as strings; only plain scalars may be numbers or booleans.
            guard scalar.style == .plain || scalar.style == .any else { return .string(scalar.string) }
            if let int = Int(scalar.string) { return .int(int) }
            // Mihomo reads YAML 1.2: only true/false are booleans (not yes/on).
            if ["true", "false"].contains(scalar.string.lowercased()) { return .bool(scalar.string.lowercased() == "true") }
            return .string(scalar.string)
        case .sequence(let sequence): return .list(sequence.compactMap(value(from:)))
        case .mapping(let mapping): return .map(mapping.compactMap { key, value in key.string.flatMap { k in Self.value(from: value).map { (k, $0) } } })
        case .alias: return nil
        }
    }

    // MARK: Generated configuration

    static func build(proxies raw: [YAMLValue], format: Format, skipped: [String: Int]) throws -> Result {
        var names = Set(ConfigDocument.builtinPolicies).union([selectGroup, autoGroup])
        var counters: [String: Int] = [:]
        var proxies: [YAMLValue] = []
        var proxyNames: [String] = []
        for proxy in raw {
            guard case .map(var pairs) = proxy, proxy["type"] != nil, proxy["server"] != nil else { continue }
            var name = (proxy["name"]?.stringValue ?? "").replacingOccurrences(of: ",", with: "，")
                .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "\(proxy["server"]?.stringValue ?? "node"):\(portText(proxy["port"]))" }
            // Same suffix style as Mihomo: name, name-01, name-02 …
            let base = name
            while names.contains(name) {
                counters[base, default: 0] += 1
                name = String(format: "%@-%02d", base, counters[base]!)
            }
            names.insert(name)
            if let index = pairs.firstIndex(where: { $0.0 == "name" }) { pairs[index].1 = .string(name) } else { pairs.insert(("name", .string(name)), at: 0) }
            proxies.append(.map(pairs))
            proxyNames.append(name)
        }
        guard !proxyNames.isEmpty else { throw EditorError("没有找到有效的节点（每个节点需要 name、type 和 server）。") }
        guard proxyNames.count <= 2500 else { throw EditorError("节点超过 2500 个，请先缩小订阅范围。") }

        var regionGroups: [(String, [String])] = []
        for region in Region.allCases where region != .unknown {
            let members = proxyNames.filter { Region.infer(from: $0) == region }
            guard !members.isEmpty else { continue }
            var groupName = "\(region.displayName)节点"
            while names.contains(groupName) { groupName += "-组" }
            names.insert(groupName)
            regionGroups.append((groupName, members))
        }

        var groups: [YAMLValue] = [
            .map([("name", .string(selectGroup)), ("type", .string("select")),
                  ("proxies", .list(([autoGroup] + regionGroups.map(\.0) + proxyNames + ["DIRECT"]).map { .string($0) }))]),
            .map([("name", .string(autoGroup)), ("type", .string("url-test")), ("url", .string("https://www.gstatic.com/generate_204")),
                  ("interval", .int(300)), ("tolerance", .int(50)), ("proxies", .list(proxyNames.map { .string($0) }))]),
        ]
        for (name, members) in regionGroups {
            groups.append(.map([("name", .string(name)), ("type", .string("select")), ("proxies", .list(members.map { .string($0) }))]))
        }

        let config: YAMLValue = .map([
            ("mixed-port", .int(7890)),
            ("allow-lan", .bool(false)),
            ("mode", .string("rule")),
            ("log-level", .string("info")),
            ("proxies", .list(proxies)),
            ("proxy-groups", .list(groups)),
            ("rules", .list([.string("MATCH,\(selectGroup)")])),
        ])
        let body = readableUnicode(try Yams.serialize(node: node(config), indent: 2, width: -1, allowUnicode: true))
        let header = "# 由 Veer 根据\(format.label)生成（\(proxyNames.count) 个节点）。\n"
        return Result(text: header + body, format: format, nodeCount: proxyNames.count, skipped: skipped)
    }

    /// libyaml writes characters outside the BMP (flag emoji) as `\UXXXXXXXX` escapes. Put the
    /// characters back so the exported file is readable; keep the escaped form if anything differs.
    static func readableUnicode(_ yaml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\\)\\U([0-9A-Fa-f]{8})"#) else { return yaml }
        var output = yaml
        for match in regex.matches(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)).reversed() {
            guard let range = Range(match.range, in: output), let hexRange = Range(match.range(at: 1), in: yaml),
                  let code = UInt32(yaml[hexRange], radix: 16), let scalar = Unicode.Scalar(code) else { continue }
            output.replaceSubrange(range, with: String(Character(scalar)))
        }
        guard let before = try? compose(yaml: yaml), let after = try? compose(yaml: output), before == after else { return yaml }
        return output
    }

    static func portText(_ value: YAMLValue?) -> String {
        switch value {
        case .int(let port): String(port)
        case .string(let port): port
        default: ""
        }
    }

    /// Strings that YAML would read as another type are quoted, so `password: '123456'` stays a string.
    static func node(_ value: YAMLValue) -> Node {
        switch value {
        case .string(let s):
            let ambiguous = s.isEmpty || Int(s) != nil || Double(s) != nil
                || ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(s.lowercased())
            return .scalar(.init(s, Tag(.str), ambiguous ? .singleQuoted : .any))
        case .int(let i): return .scalar(.init(String(i), Tag(.int), .plain))
        case .bool(let b): return .scalar(.init(b ? "true" : "false", Tag(.bool), .plain))
        case .list(let items): return .sequence(.init(items.map(node), Tag(.seq), .block))
        case .map(let pairs): return .mapping(.init(pairs.map { (Node.scalar(.init($0.0)), node($0.1)) }, Tag(.map), .block))
        }
    }
}
