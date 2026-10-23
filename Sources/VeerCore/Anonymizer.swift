import Foundation

/// Builds the anonymous view of a configuration that is the only thing an AI service sees.
public struct AnonymousContext: Sendable {
    public struct Exit: Sendable, Hashable {
        public let id: String
        public let label: String
        public let kind: Target.Kind
    }

    public let exits: [Exit]
    /// Real name → anonymous label, for non-built-in exits only.
    let labels: [(name: String, label: String)]

    public init(targets: [Target], regions: [String: Region]) {
        var groups = 0, nodes = 0
        var exits: [Exit] = []
        var labels: [(String, String)] = []
        for target in targets {
            if target.kind == .builtin {
                exits.append(Exit(id: target.id, label: target.name, kind: .builtin))
                continue
            }
            let region = regions[target.name] ?? .unknown
            let suffix = region == .unknown ? "" : "（\(region.displayName)）"
            let label: String
            if target.kind == .group {
                groups += 1
                label = "策略组\(groups)\(suffix)"
            } else {
                nodes += 1
                label = "节点\(nodes)\(suffix)"
            }
            exits.append(Exit(id: target.id, label: label, kind: target.kind))
            labels.append((target.name, label))
        }
        self.exits = exits
        self.labels = labels.sorted { $0.0.count > $1.0.count }
    }

    /// Replaces real exit names (and `@name` mentions) with their labels, longest name first.
    public func anonymize(_ text: String) -> String {
        guard !labels.isEmpty else { return text }
        var output = ""
        var index = text.startIndex
        outer: while index < text.endIndex {
            for (name, label) in labels {
                if text[index...].hasPrefix("@" + name) {
                    output += label
                    index = text.index(index, offsetBy: name.count + 1)
                    continue outer
                }
                if text[index...].hasPrefix(name) {
                    output += label
                    index = text.index(index, offsetBy: name.count)
                    continue outer
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    public func label(forTargetID id: String) -> String? { exits.first { $0.id == id }?.label }

    /// Puts real exit names back into text the model wrote (a question, an option): labels with or
    /// without their region (“策略组2（日本）”, “策略组2”) and target ids.
    public func restore(_ text: String) -> String {
        var pairs: [(String, String)] = labels.flatMap { name, label in
            [(label, name), (String(label.prefix { $0 != "（" }), name)]
        }
        let names = Dictionary(labels.map { ($0.label, $0.name) }, uniquingKeysWith: { first, _ in first })
        pairs += exits.map { ($0.id, names[$0.label] ?? $0.label) }
        pairs.sort { $0.0.count > $1.0.count }
        var output = "", index = text.startIndex
        outer: while index < text.endIndex {
            for (key, value) in pairs where text[index...].hasPrefix(key) {
                output += value
                index = text.index(index, offsetBy: key.count)
                continue outer
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    /// Label for a real exit name; built-ins keep their name.
    public func label(forName name: String) -> String? {
        if ConfigDocument.builtinPolicies.contains(name) { return name }
        return labels.first { $0.name == name }?.label
    }
}
