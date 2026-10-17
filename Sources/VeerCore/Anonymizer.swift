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
        var number = 0
        var exits: [Exit] = []
        var labels: [(String, String)] = []
        for target in targets {
            if target.kind == .builtin {
                exits.append(Exit(id: target.id, label: target.name, kind: .builtin))
            } else {
                number += 1
                let region = regions[target.name] ?? .unknown
                let label = "出口\(number)（\(region == .unknown ? "未指定地区" : region.displayName)）"
                exits.append(Exit(id: target.id, label: label, kind: target.kind))
                labels.append((target.name, label))
            }
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
}
