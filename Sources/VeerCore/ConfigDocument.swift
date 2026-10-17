import Foundation
import Yams

/// A parsed Mihomo configuration. Holds the original text verbatim plus the facts the
/// editor needs; secrets stay in `text` and are never copied into other fields.
public struct ConfigDocument: Sendable {
    public static let maxBytes = 2 * 1024 * 1024
    public static let builtinPolicies: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

    public struct Counts: Sendable, Equatable {
        public let nodes: Int
        public let groups: Int
        public let rules: Int
        public let providers: Int
    }

    public struct Provider: Sendable, Equatable {
        public let key: String
        public let url: String?
        public let path: String?
    }

    public let text: String
    public let targets: [Target]
    public let rules: [String]
    public let providers: [Provider]
    public let mode: String?
    public let warnings: [String]
    public let counts: Counts

    /// Top-level keys with their 0-based source line, in document order.
    let topLevelKeys: [(key: String, line: Int)]

    public func target(id: String) -> Target? { targets.first { $0.id == id } }
    public func target(named name: String) -> Target? { targets.first { $0.name == name } }

    public static func parse(_ text: String) throws -> ConfigDocument {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorError("配置是空的。请导入 Mihomo YAML 配置。")
        }
        guard text.utf8.count <= maxBytes else { throw EditorError("配置超过 2 MB，请先拆分后再导入。") }
        if text.contains("\t") && text.split(separator: "\n").contains(where: { $0.hasPrefix("\t") }) {
            throw EditorError("YAML 不能用 Tab 缩进，请改为空格。")
        }
        if aliasCount(in: text) > 100 { throw EditorError("配置中的 YAML 锚点引用超过 100 次，无法安全展开。") }

        let root: Node
        do {
            var documents = try compose_all(yaml: text).makeIterator()
            let first = documents.next()
            if let error = documents.error { throw error }
            guard let first else { throw EditorError("配置是空的。请导入 Mihomo YAML 配置。") }
            if documents.next() != nil { throw EditorError("配置包含多个 YAML 文档，请只保留一个。") }
            if let error = documents.error { throw error }
            root = first
        } catch let error as EditorError {
            throw error
        } catch {
            throw EditorError("YAML 无法解析：\(describe(error))")
        }
        guard let mapping = root.mapping else { throw EditorError("配置顶层必须是 YAML 映射（key: value）。") }

        var keys: [(String, Int)] = []
        for (key, _) in mapping {
            guard let name = key.string, let mark = key.mark else { throw EditorError("配置顶层的键无法识别。") }
            keys.append((name, mark.line - 1))
        }
        if Set(keys.map(\.1)).count != keys.count {
            throw EditorError("不支持单行（flow）格式的顶层配置，请使用常规的多行 YAML。")
        }

        func array(_ key: String) throws -> [Node]? {
            guard let node = mapping[key] else { return nil }
            if case .scalar(let scalar) = node, scalar.string.isEmpty || scalar.string == "~" || scalar.string == "null" { return [] }
            guard let sequence = node.sequence else { throw EditorError("\(key) 必须是数组。") }
            return Array(sequence)
        }

        let proxies = try array("proxies") ?? []
        let groups = try array("proxy-groups") ?? []
        let ruleNodes = try array("rules") ?? []

        var names = builtinPolicies
        func name(of node: Node) throws -> String {
            guard let name = node.mapping?["name"]?.string, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw EditorError("节点和策略组必须有有效名称。")
            }
            if name.contains(",") || name.contains("\n") || name.contains("\r") {
                throw EditorError("出口名称含逗号或换行，无法在规则中安全引用：\(name.prefix(60))")
            }
            guard names.insert(name).inserted else { throw EditorError("节点或策略组名称重复：\(name.prefix(60))") }
            return name
        }
        let proxyNames = try proxies.map(name(of:))
        let groupNames = try groups.map(name(of:))

        let proxyProviderNames = Set(mapping["proxy-providers"]?.mapping?.compactMap { $0.key.string } ?? [])
        var children: [String: [String]] = [:]
        for (group, groupName) in zip(groups, groupNames) {
            let members = group.mapping?["proxies"]
            if let members, members.sequence == nil { throw EditorError("策略组 \(groupName) 的 proxies 必须是数组。") }
            let refs = members?.sequence?.compactMap(\.string) ?? []
            for ref in refs where !names.contains(ref) {
                throw EditorError("策略组 \(groupName) 引用了不存在的出口：\(ref.prefix(60))")
            }
            children[groupName] = refs
            if let use = group.mapping?["use"] {
                guard let uses = use.sequence else { throw EditorError("策略组 \(groupName) 的 use 必须是数组。") }
                for ref in uses.compactMap(\.string) where !proxyProviderNames.contains(ref) {
                    throw EditorError("策略组 \(groupName) 引用了不存在的 Provider：\(ref.prefix(60))")
                }
            }
        }
        try checkCycles(children)

        var rules: [String] = []
        for node in ruleNodes {
            guard let scalar = node.scalar else { throw EditorError("rules 中每一项必须是规则字符串。") }
            rules.append(scalar.string)
        }

        var providers: [Provider] = []
        if let node = mapping["rule-providers"] {
            if let providerMap = node.mapping {
                for (key, value) in providerMap {
                    guard let key = key.string else { throw EditorError("rule-providers 的名称无法识别。") }
                    providers.append(Provider(key: key, url: value.mapping?["url"]?.string, path: value.mapping?["path"]?.string))
                }
            } else if !(node.scalar.map { $0.string.isEmpty || $0.string == "null" || $0.string == "~" } ?? false) {
                throw EditorError("rule-providers 必须是映射。")
            }
        }

        var targets: [Target] = []
        for (group, name) in zip(groups, groupNames) {
            targets.append(Target(id: "target-\(targets.count)", name: name, kind: .group, type: group.mapping?["type"]?.string))
        }
        for (proxy, name) in zip(proxies, proxyNames) {
            targets.append(Target(id: "target-\(targets.count)", name: name, kind: .node, type: proxy.mapping?["type"]?.string))
        }
        targets.append(Target(id: "target-\(targets.count)", name: "DIRECT", kind: .builtin))
        targets.append(Target(id: "target-\(targets.count)", name: "REJECT", kind: .builtin))

        let mode = mapping["mode"]?.string
        var warnings: [String] = []
        if proxies.isEmpty && groups.isEmpty {
            warnings.append("没有静态节点或策略组。只能使用 DIRECT 和 REJECT；动态 Provider 的节点需先通过策略组引用。")
        }
        if !rules.contains(where: { $0.uppercased().hasPrefix("MATCH,") }) {
            warnings.append("配置没有 MATCH 兜底规则，未命中任何规则的流量行为取决于内核默认值。")
        }
        if let mode, mode.lowercased() != "rule" {
            warnings.append("当前 mode 为 \(mode)，只有在 rule 模式下分流规则才会生效。Veer 不会修改 mode。")
        }

        let ruleProviderCount = providers.count
        return ConfigDocument(
            text: text,
            targets: targets,
            rules: rules,
            providers: providers,
            mode: mode,
            warnings: warnings,
            counts: Counts(nodes: proxies.count, groups: groups.count, rules: rules.count, providers: proxyProviderNames.count + ruleProviderCount),
            topLevelKeys: keys
        )
    }

    private static func checkCycles(_ children: [String: [String]]) throws {
        var done = Set<String>()
        func visit(_ name: String, _ path: [String]) throws {
            if path.contains(name) { throw EditorError("策略组存在循环引用：\((path + [name]).joined(separator: " → "))") }
            if path.count > 64 { throw EditorError("策略组嵌套超过 64 层，请先简化配置。") }
            if done.contains(name) { return }
            for child in children[name] ?? [] where children[child] != nil { try visit(child, path + [name]) }
            done.insert(name)
        }
        for name in children.keys.sorted() { try visit(name, []) }
    }

    static func aliasCount(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s\[{,:-])\*[^\s,\[\]{}]+"#) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func describe(_ error: Error) -> String {
        if let yamlError = error as? YamlError {
            switch yamlError {
            case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _):
                return "第 \(mark.line) 行：\(problem)"
            case .composer(_, let problem, let mark, _):
                return "第 \(mark.line) 行：\(problem)"
            case .duplicatedKeysInMapping(let duplicates, _):
                let key = duplicates.first ?? "?"
                return "存在重复的键 \(key)"
            default:
                return "格式错误"
            }
        }
        return "格式错误"
    }
}
