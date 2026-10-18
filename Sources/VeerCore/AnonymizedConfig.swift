import Foundation
import Yams

/// The anonymized, de-featured YAML view of a draft: the only configuration content an AI
/// service receives.
///
/// Kept: structure (which groups exist, their type, which exits they contain), declared or
/// inferred regions, `mode`, and rules with anonymous targets. Removed: every real name, all
/// node fields (server, port, password, uuid, cipher, transport, TLS/SNI, keys), protocol types,
/// health-check URLs, provider URLs and paths, and every other top-level key (DNS, TUN,
/// listeners, controller). Literal domains and IPs in rules become placeholders unless the user
/// opts in; public category names (GEOSITE/GEOIP tags, catalog rule-set names) stay readable.
public struct AnonymizedConfig: Sendable {
    public let yaml: String
    public let context: AnonymousContext

    /// Groups with more members than this are summarized as counts by region.
    public static let memberListLimit = 24
    /// Rules beyond this are summarized; the model never needs the long tail.
    public static let ruleLimit = 300

    static let catalogNames: Set<String> = Set(
        (SystemPrompt.geositeNames + SystemPrompt.geoipNames.map { "\($0)-ip" } + SystemPrompt.acl4ssrNames.map { String($0.split(separator: "/").last!) }
            + SystemPrompt.blackmatrix7Names).map { $0.lowercased() }
    )

    public static func make(document: ConfigDocument, regions: [String: Region], shareRuleLiterals: Bool = false) -> AnonymizedConfig {
        let context = AnonymousContext(targets: document.targets, regions: regions)
        let analysis = ProfileAnalysis.analyze(document.text)
        let labelMap = Dictionary(context.labels.map { ($0.name, $0.label) }, uniquingKeysWith: { a, _ in a })
        func label(_ name: String) -> String {
            ConfigDocument.builtinPolicies.contains(name) ? name : labelMap[name] ?? "未知出口"
        }

        var root: [(String, Node)] = []
        if let mode = document.mode { root.append(("mode", scalar(mode))) }
        root.append(("内置出口", .sequence(.init(document.targets.filter { $0.kind == .builtin }.map { target in
            flowMap([("id", scalar(target.id)), ("name", scalar(target.name))])
        }, Tag(.seq), .block))))

        let nodes = document.targets.filter { $0.kind == .node }
        if !nodes.isEmpty {
            root.append(("proxies", .sequence(.init(nodes.map { target in
                flowMap([("id", scalar(target.id)), ("name", scalar(label(target.name)))])
            }, Tag(.seq), .block))))
        }

        let groups = analysis?.groups ?? []
        if !groups.isEmpty {
            let groupIDs = Dictionary(document.targets.filter { $0.kind == .group }.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            var providerLabels: [String: String] = [:]
            for (index, provider) in (analysis?.providers ?? []).enumerated() { providerLabels[provider.name] = "代理集\(index + 1)" }
            root.append(("proxy-groups", .sequence(.init(groups.map { group in
                var pairs: [(String, Node)] = [("id", scalar(groupIDs[group.name] ?? "")), ("name", scalar(label(group.name))),
                                               ("type", scalar(mihomoType(group.type)))]
                let members = group.members.filter { $0.kind != .missing }
                if members.count <= memberListLimit {
                    pairs.append(("proxies", flowSeq(members.map { label($0.name) })))
                } else {
                    // Summarize: how many nodes per region, and which groups/built-ins are inside.
                    var byRegion: [String: Int] = [:]
                    var others: [String] = []
                    for member in members {
                        if member.kind == .proxy {
                            let region = regions[member.name] ?? .unknown
                            byRegion[region == .unknown ? "未指定地区" : region.displayName, default: 0] += 1
                        } else {
                            others.append(label(member.name))
                        }
                    }
                    var summary: [(String, Node)] = [("节点数", scalar(String(members.count - others.count), tag: .int))]
                    if !byRegion.isEmpty {
                        summary.append(("按地区", flowMap(byRegion.sorted { $0.value > $1.value }.map { ($0.key, scalar(String($0.value), tag: .int)) })))
                    }
                    if !others.isEmpty { summary.append(("其他成员", flowSeq(others))) }
                    pairs.append(("proxies", .mapping(.init(summary.map { (scalar($0.0), $0.1) }, Tag(.map), .block))))
                }
                if !group.providers.isEmpty { pairs.append(("use", flowSeq(group.providers.map { providerLabels[$0] ?? "代理集" }))) }
                if group.includesAll { pairs.append(("include-all", scalar("true", tag: .bool))) }
                return .mapping(.init(pairs.map { (scalar($0.0), $0.1) }, Tag(.map), .block))
            }, Tag(.seq), .block))))
        }

        // Rule providers: behavior only. Public catalog names stay; anything else is renamed.
        var providerNames: [String: String] = [:]
        var anonymousProviders = 0
        for provider in document.providers {
            if catalogNames.contains(provider.key.lowercased()) {
                providerNames[provider.key] = provider.key
            } else {
                anonymousProviders += 1
                providerNames[provider.key] = "规则集\(anonymousProviders)"
            }
        }
        if !document.providers.isEmpty {
            let behaviors = providerBehaviors(document.text)
            root.append(("rule-providers", .mapping(.init(document.providers.map { provider in
                (scalar(providerNames[provider.key]!), flowMap([("behavior", scalar(behaviors[provider.key] ?? "unknown"))]))
            }, Tag(.map), .block))))
        }

        var literals: [String: String] = [:]
        func placeholder(_ value: String, kind: String) -> String {
            if shareRuleLiterals { return value }
            if let existing = literals[value.lowercased()] { return existing }
            let token = "<\(kind)\(literals.count + 1)>"
            literals[value.lowercased()] = token
            return token
        }
        var rules: [String] = []
        for rule in document.rules.prefix(ruleLimit) {
            rules.append(anonymize(rule: rule, label: label, providerNames: providerNames, placeholder: placeholder))
        }
        if document.rules.count > ruleLimit { rules.append("# 另有 \(document.rules.count - ruleLimit) 条规则未列出") }
        if !rules.isEmpty { root.append(("rules", .sequence(.init(rules.map { scalar($0) }, Tag(.seq), .block)))) }

        let header = """
        # Veer 匿名配置：名称已替换为标签，修改出口时使用 id。
        # 已移除：真实名称、节点地址/端口/密码/协议参数、订阅与规则集地址、DNS/TUN 等其他配置。
        \(shareRuleLiterals ? "" : "# 规则中的具体域名和 IP 已替换为 <域名N> / <IPN> 占位符。\n")
        """
        let body = (try? Yams.serialize(node: .mapping(.init(root.map { (scalar($0.0), $0.1) }, Tag(.map), .block)),
                                        indent: 2, width: -1, allowUnicode: true)) ?? ""
        return AnonymizedConfig(yaml: header + ConfigImporter.readableUnicode(body), context: context)
    }

    static func anonymize(rule: String, label: (String) -> String, providerNames: [String: String],
                          placeholder: (String, String) -> String) -> String {
        guard let parsed = ProfileAnalysis.parseRule(rule) else { return "<无法解析的规则>" }
        let type = parsed.type
        let target = label(parsed.target)
        if type == "MATCH" { return "MATCH,\(target)" }
        let parts = rule.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let payload = parts.count > 1 ? parts[1] : ""
        let flags = rule.hasSuffix(",no-resolve") ? ",no-resolve" : ""
        let value: String
        switch type {
        case "GEOSITE", "GEOIP", "NETWORK", "DST-PORT", "SRC-PORT", "IN-TYPE": value = payload
        case "RULE-SET": value = providerNames[payload] ?? "规则集"
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX": value = placeholder(payload, "域名")
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "IP-SUFFIX", "IP-ASN": value = placeholder(payload, "IP")
        case "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX": value = placeholder(payload, "进程")
        case "AND", "OR", "NOT", "SUB-RULE": value = "<逻辑条件>"
        default: value = placeholder(payload, "值")
        }
        return "\(type),\(value),\(target)\(flags)"
    }

    /// ProfileAnalysis keeps display labels (URLTest); the model should see Mihomo's names (url-test).
    static func mihomoType(_ label: String) -> String {
        ProfileAnalysis.groupTypeLabels.first { $0.value == label }?.key ?? label.lowercased()
    }

    static func providerBehaviors(_ text: String) -> [String: String] {
        guard let providers = (try? compose(yaml: text))??.mapping?["rule-providers"]?.mapping else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in providers { if let key = key.string { result[key] = value.mapping?["behavior"]?.string } }
        return result
    }

    static func scalar(_ value: String, tag: Tag.Name = .str) -> Node {
        let ambiguous = tag == .str && (value.isEmpty || Int(value) != nil || ["true", "false", "null", "~"].contains(value.lowercased()))
        return .scalar(.init(value, Tag(tag), ambiguous ? .singleQuoted : .any))
    }

    static func flowMap(_ pairs: [(String, Node)]) -> Node { .mapping(.init(pairs.map { (scalar($0.0), $0.1) }, Tag(.map), .flow)) }
    static func flowSeq(_ items: [String]) -> Node { .sequence(.init(items.map { scalar($0) }, Tag(.seq), .flow)) }
}
