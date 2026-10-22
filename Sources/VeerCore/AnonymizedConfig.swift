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
    /// What each part of the original became, for the side-by-side view. Kept on this Mac only.
    public let comparison: PayloadComparison
    /// Anonymous rule-set label ("规则集1") → real rule-set name, for plans that delete a rule set.
    let ruleSetNames: [String: String]

    /// A plan may delete a rule set by the label it saw; put the real name back.
    func restoringRuleSetNames(in reply: AssistantReply) -> AssistantReply {
        guard case .plan(var plan) = reply else { return reply }
        plan.operations = plan.operations.map { op in
            if case let .removeRule(type, match) = op, type == "RULE-SET", let real = ruleSetNames[match] { return .removeRule(matchType: type, match: real) }
            return op
        }
        return .plan(plan)
    }

    /// Groups with more members than this are summarized as counts by region.
    public static let memberListLimit = 24
    /// Nodes beyond this are summarized by region; the model reaches them through regional groups
    /// or a new group's `regions`, so listing thousands only costs tokens.
    public static let nodeListLimit = 200
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
        var sections: [PayloadComparison.Section] = []
        func section(_ title: String, _ pairs: [(String, String)], note: String? = nil) {
            guard !pairs.isEmpty else { return }
            sections.append(.init(title: title, rows: pairs.enumerated().map { .init(id: "\(title)#\($0.offset)", original: $0.element.0, sent: $0.element.1) }, note: note))
        }
        if let mode = document.mode { root.append(("mode", scalar(mode))) }
        root.append(("内置出口", .sequence(.init(document.targets.filter { $0.kind == .builtin }.map { target in
            flowMap([("id", scalar(target.id)), ("name", scalar(target.name))])
        }, Tag(.seq), .block))))

        let nodes = document.targets.filter { $0.kind == .node }
        var listedNodes = nodes
        if nodes.count > nodeListLimit {
            // Prefer nodes that small groups name directly; those are the ones a plan might use.
            let named = Set((analysis?.groups ?? []).filter { $0.members.count <= memberListLimit }.flatMap { $0.members.map(\.name) })
            listedNodes = Array((nodes.filter { named.contains($0.name) } + nodes.filter { !named.contains($0.name) }).prefix(nodeListLimit))
        }
        let listedNames = Set(listedNodes.map(\.name))
        let unlisted = nodes.filter { !listedNames.contains($0.name) }
        section("节点", nodes.map { ($0.name, listedNames.contains($0.name) ? label($0.name) : "未逐个发送（按地区计数）") },
                note: unlisted.isEmpty ? "服务器、端口、密码、UUID、协议与传输参数都不发送" : "服务器、端口、密码等都不发送；超过 \(nodeListLimit) 个时其余节点只发送按地区的数量")
        if !listedNodes.isEmpty {
            root.append(("proxies", .sequence(.init(nodes.filter { listedNames.contains($0.name) }.map { target in
                flowMap([("id", scalar(target.id)), ("name", scalar(label(target.name)))])
            }, Tag(.seq), .block))))
        }
        if !unlisted.isEmpty {
            var byRegion: [String: Int] = [:]
            for node in unlisted {
                let region = regions[node.name] ?? .unknown
                byRegion[region == .unknown ? "未指定地区" : region.displayName, default: 0] += 1
            }
            root.append(("未列出的节点", .mapping(.init([
                (scalar("数量"), scalar(String(unlisted.count), tag: .int)),
                (scalar("按地区"), flowMap(byRegion.sorted { $0.value > $1.value }.map { ($0.key, scalar(String($0.value), tag: .int)) })),
                (scalar("说明"), scalar("使用地区策略组，或新建策略组时用 regions 选择这些节点")),
            ], Tag(.map), .block))))
        }

        let groups = analysis?.groups ?? []
        section("策略组", groups.map { group in
            let type = mihomoType(group.type)
            return ("\(group.name) · \(type)", "\(label(group.name)) · \(type)")
        }, note: "健康检查地址不发送")
        section("代理集", (analysis?.providers ?? []).enumerated().map { ($0.element.name, "代理集\($0.offset + 1)") }, note: "订阅地址与路径不发送")
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
        section("规则集", document.providers.map { ($0.key, providerNames[$0.key]!) }, note: "地址与路径不发送；公共规则集保留名称")
        if !document.providers.isEmpty {
            let behaviors = providerBehaviors(document.text)
            root.append(("rule-providers", .mapping(.init(document.providers.map { provider in
                (scalar(providerNames[provider.key]!), flowMap([("behavior", scalar(behaviors[provider.key] ?? "unknown"))]))
            }, Tag(.map), .block))))
        }

        var literals: [String: String] = [:]
        var literalRows: [(String, String)] = []
        func placeholder(_ value: String, kind: String) -> String {
            if shareRuleLiterals { return value }
            if let existing = literals[value.lowercased()] { return existing }
            let token = "<\(kind)\(literals.count + 1)>"
            literals[value.lowercased()] = token
            literalRows.append((value, token))
            return token
        }
        var rules: [String] = []
        for rule in document.rules.prefix(ruleLimit) {
            rules.append(anonymize(rule: rule, label: label, providerNames: providerNames, placeholder: placeholder))
        }
        if document.rules.count > ruleLimit { rules.append("# 另有 \(document.rules.count - ruleLimit) 条规则未列出") }
        section("规则", Array(zip(document.rules.prefix(ruleLimit), rules)),
                note: document.rules.count > ruleLimit ? "只发送前 \(ruleLimit) 条，另有 \(document.rules.count - ruleLimit) 条未发送" : nil)
        section("规则中的具体值", literalRows, note: "同一个值始终替换为同一个占位符")
        let sent: Set<String> = ["mode", "proxies", "proxy-groups", "rules", "rule-providers", "proxy-providers"]
        section("未发送的配置", document.topLevelKeys.map(\.key).filter { !sent.contains($0) }.map { ($0, "未发送") })
        if !rules.isEmpty { root.append(("rules", .sequence(.init(rules.map { scalar($0) }, Tag(.seq), .block)))) }

        let header = """
        # Veer 匿名配置：名称已替换为标签，修改出口时使用 id。
        # 已移除：真实名称、节点地址/端口/密码/协议参数、订阅与规则集地址、DNS/TUN 等其他配置。
        \(shareRuleLiterals ? "" : "# 规则中的具体域名和 IP 已替换为 <域名N> / <IPN> 占位符。\n")
        """
        let body = (try? Yams.serialize(node: .mapping(.init(root.map { (scalar($0.0), $0.1) }, Tag(.map), .block)),
                                        indent: 2, width: -1, allowUnicode: true)) ?? ""
        return AnonymizedConfig(yaml: header + ConfigImporter.readableUnicode(body), context: context,
                                comparison: PayloadComparison(sections: sections),
                                ruleSetNames: Dictionary(providerNames.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a }))
    }

    static func anonymize(rule: String, label: (String) -> String, providerNames: [String: String],
                          placeholder: (String, String) -> String) -> String {
        guard let parsed = RuleParts.parse(rule) else { return "<无法解析的规则>" }
        let type = parsed.type
        let target = label(parsed.target)
        guard let payload = parsed.payload else { return "MATCH,\(target)" }
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
    static func mihomoType(_ label: String) -> String { ProfileAnalysis.mihomoType(label) }

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

/// Original configuration next to what the AI received, item by item.
public struct PayloadComparison: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        /// Unique across sections ("规则#3"), so one list can hold every section.
        public let id: String
        public let original: String
        public let sent: String
        public init(id: String, original: String, sent: String) {
            self.id = id
            self.original = original
            self.sent = sent
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public let title: String
        public let rows: [Row]
        public let note: String?
        public init(title: String, rows: [Row], note: String?) {
            self.title = title
            self.rows = rows
            self.note = note
        }
    }

    public let sections: [Section]

    /// The comparison for a turn: rebuilt from the draft the payload came from. `exact` is false
    /// when the rebuilt YAML differs from what was sent (for example after a region correction).
    public static func rebuild(for payload: AIRequestPayload, source: String, regions: (ConfigDocument) -> [String: Region]) -> (comparison: PayloadComparison, exact: Bool)? {
        guard let document = try? ConfigDocument.parse(source) else { return nil }
        let shared = payload.shareRuleLiterals ?? !(payload.config ?? "").contains("已替换为 <域名N>")
        let rebuilt = AnonymizedConfig.make(document: document, regions: regions(document), shareRuleLiterals: shared)
        return (rebuilt.comparison, payload.config == nil || rebuilt.yaml == payload.config)
    }
}
