import Foundation
import Yams

/// Recognizes what an imported file or subscription contains and turns it into a Mihomo
/// configuration. Detection order follows Mihomo's own provider parser: YAML first, then
/// Base64-or-plain share links.
public enum ConfigImporter {
    public enum Format: String, Sendable, Codable {
        case mihomoYAML, proxyListYAML, base64Links, plainLinks, merged

        public var label: String {
            switch self {
            case .mihomoYAML: "Mihomo / Clash 配置"
            case .proxyListYAML: "YAML 节点列表"
            case .base64Links: "Base64 订阅（分享链接）"
            case .plainLinks: "分享链接列表"
            case .merged: "多个订阅合并"
            }
        }
    }

    /// One subscription (or pasted source) of a merged import.
    public struct Part: Sendable, Equatable {
        public let label: String
        public let text: String

        public init(label: String, text: String) {
            self.label = label
            self.text = text
        }
    }

    /// How many nodes each merged subscription contributed, before clean-up.
    public struct SourceCount: Sendable, Equatable {
        public let label: String
        public let nodes: Int
    }

    public struct Result: Sendable {
        public let text: String
        public let format: Format
        public let nodeCount: Int
        public let skipped: [String: Int]
        public var cleanup = CleanupReport()
        public var sources: [SourceCount] = []
        /// Nodes renamed with their subscription's name because another subscription used the name.
        public var prefixed = 0

        /// Explains a conversion to the user; nil when the input was already a full config.
        public var note: String? {
            guard format != .mihomoYAML else { return nil }
            let generated = "Veer 生成了一份基础 Mihomo 配置：“节点选择”“自动选择”和按地区分组的策略组，规则只有 MATCH 兜底，可以接着用对话添加分流。"
            var text: String
            if format == .merged {
                let list = sources.map { "\($0.label)（\($0.nodes) 个）" }.joined(separator: "、")
                text = "合并了 \(sources.count) 个订阅：\(list)，清理后共 \(nodeCount) 个节点。只取各订阅的节点，" + generated
                if prefixed > 0 { text += "有 \(prefixed) 个节点与其他订阅重名，已在名称前加上订阅名。" }
            } else {
                text = "已识别为\(format.label)，共 \(nodeCount) 个节点。" + generated
            }
            if !skipped.isEmpty {
                let detail = skipped.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) 个" }.joined(separator: "、")
                text += "无法转换、已跳过：\(detail)。"
            }
            if let summary = cleanup.summary { text += summary }
            return text + "导出的是生成后的完整配置，不是原始订阅内容。"
        }
    }

    public static let selectGroup = "节点选择"
    public static let autoGroup = "自动选择"

    /// What a piece of content holds: a full config to pass through, or nodes to build one from.
    enum Detected {
        case config(text: String, nodeCount: Int)
        case nodes(Format, [YAMLValue], skipped: [String: Int])
    }

    public static func normalize(_ raw: String, options: ImportOptions = .init()) throws -> Result {
        switch try detect(raw) {
        case .config(let text, let count):
            return Result(text: text, format: .mihomoYAML, nodeCount: count, skipped: [:])
        case .nodes(let format, let proxies, let skipped):
            return try build(proxies: proxies, format: format, skipped: skipped, options: options)
        }
    }

    static func detect(_ raw: String) throws -> Detected {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorError("内容是空的。请导入 Mihomo YAML 配置、Base64 订阅或分享链接列表。") }
        guard trimmed.utf8.count <= ConfigDocument.maxBytes else { throw EditorError("内容超过 2 MB，请先拆分后再导入。") }
        if trimmed.range(of: #"^\s*(<!doctype html|<html)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw EditorError("这是一个网页，不是配置。订阅链接可能已失效、需要登录，或返回了错误页面。")
        }

        if let yaml = try yamlContent(text) { return yaml }

        if let decoded = ShareLinkParser.base64String(trimmed), decoded.contains("://") || decoded.contains(":") {
            if decoded.contains("://") { return try links(decoded, format: .base64Links) }
            if let yaml = try? yamlContent(decoded) { return yaml }
        }
        if trimmed.contains("://") { return try links(trimmed, format: .plainLinks) }
        throw EditorError("无法识别这份内容。Veer 支持 Mihomo / Clash YAML 配置、YAML 节点列表、Base64 订阅和分享链接列表（ss、ssr、vmess、vless、trojan、hysteria、hysteria2、tuic、socks5、http、anytls）。")
    }

    /// nil when the text is not YAML that Veer can use (a scalar, or unparsable).
    static func yamlContent(_ text: String) throws -> Detected? {
        guard let node = try? compose(yaml: text) else { return nil }
        if let mapping = node.mapping {
            let keys = Set(mapping.keys.compactMap(\.string))
            if keys.contains("outbounds") && (keys.contains("inbounds") || keys.contains("route")) {
                throw EditorError("这是 sing-box 配置。Veer 目前只编辑 Mihomo 配置，请导入 Mihomo / Clash 格式的订阅。")
            }
            if keys == ["proxies"], let list = mapping["proxies"]?.sequence {
                return .nodes(.proxyListYAML, list.compactMap(value(from:)), skipped: [:])
            }
            return .config(text: text, nodeCount: mapping["proxies"]?.sequence?.count ?? 0)
        }
        if let sequence = node.sequence, !sequence.isEmpty,
           sequence.allSatisfy({ $0.mapping?["name"] != nil && $0.mapping?["type"] != nil }) {
            return .nodes(.proxyListYAML, sequence.compactMap(value(from:)), skipped: [:])
        }
        return nil
    }

    static func links(_ text: String, format: Format) throws -> Detected {
        let parsed = ShareLinkParser.parse(text)
        guard !parsed.proxies.isEmpty else {
            let schemes = parsed.skipped.keys.sorted().joined(separator: "、")
            throw EditorError(schemes.isEmpty ? "没有找到可以识别的分享链接。" : "没有可以转换的节点：\(schemes) 链接格式无法识别或不受支持。")
        }
        let proxies = parsed.proxies.map { proxy in proxy.map { ($0.0, $0.1) } }
        return .nodes(format, proxies.map { .map($0) }, skipped: parsed.skipped)
    }

    /// Merges the nodes of several subscriptions into one generated config. A full config gives
    /// only its proxies; groups and rules are generated as for a single node list. A name used
    /// by more than one subscription gets that subscription's name in front.
    public static func merge(_ parts: [Part], options: ImportOptions = .init()) throws -> Result {
        guard parts.count > 1 else { return try normalize(parts.first?.text ?? "", options: options) }
        var sources: [(label: String, proxies: [YAMLValue])] = []
        var skipped: [String: Int] = [:]
        for part in parts {
            var proxies: [YAMLValue] = []
            do {
                switch try detect(part.text) {
                case .config(let text, _):
                    proxies = (try compose(yaml: text)?.mapping?["proxies"]?.sequence.map(Array.init) ?? []).compactMap(value(from:))
                case .nodes(_, let list, let partSkipped):
                    proxies = list
                    skipped.merge(partSkipped, uniquingKeysWith: +)
                }
            } catch let error as EditorError {
                throw EditorError("“\(part.label)”：\(error.message)")
            }
            guard !proxies.isEmpty else { throw EditorError("“\(part.label)”里没有节点。") }
            sources.append((part.label, proxies))
        }

        var owners: [String: Set<Int>] = [:]
        for (index, source) in sources.enumerated() {
            for proxy in source.proxies { owners[proxy["name"]?.stringValue ?? "", default: []].insert(index) }
        }
        var merged: [YAMLValue] = []
        var prefixed = 0
        for source in sources {
            for proxy in source.proxies {
                let name = proxy["name"]?.stringValue ?? ""
                guard !name.isEmpty, (owners[name]?.count ?? 0) > 1, case .map(var pairs) = proxy,
                      let index = pairs.firstIndex(where: { $0.0 == "name" }) else { merged.append(proxy); continue }
                pairs[index].1 = .string("\(source.label) \(name)")
                merged.append(.map(pairs))
                prefixed += 1
            }
        }
        var result = try build(proxies: merged, format: .merged, skipped: skipped, options: options)
        result.sources = sources.map { SourceCount(label: $0.label, nodes: $0.proxies.count) }
        result.prefixed = prefixed
        return result
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

    static func build(proxies raw: [YAMLValue], format: Format, skipped: [String: Int], options: ImportOptions = .init()) throws -> Result {
        let named: [(String, YAMLValue)] = raw.compactMap { proxy in
            guard case .map = proxy, proxy["type"] != nil, proxy["server"] != nil else { return nil }
            let name = (proxy["name"]?.stringValue ?? "").replacingOccurrences(of: ",", with: "，")
                .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? "\(proxy["server"]?.stringValue ?? "node"):\(portText(proxy["port"]))" : name, proxy)
        }
        let (cleaned, report) = try NodeCleanup.apply(named, options: options)

        var names = Set(ConfigDocument.builtinPolicies).union([selectGroup, autoGroup])
        var counters: [String: Int] = [:]
        var proxies: [YAMLValue] = []
        var proxyNames: [String] = []
        for (cleanName, proxy) in cleaned {
            guard case .map(var pairs) = proxy else { continue }
            var name = cleanName
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
        return Result(text: header + body, format: format, nodeCount: proxyNames.count, skipped: skipped, cleanup: report)
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
