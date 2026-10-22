import Foundation

/// What changed between two configurations, in terms people recognize: groups, rules and rule
/// sets instead of YAML lines. Drives the visual change view.
public struct ConfigDiff: Sendable, Equatable {
    public struct GroupChange: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let oldType: String
        public let newType: String
        public let added: [String]
        public let removed: [String]
    }

    public struct RuleChange: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case added, removed }
        public var id: String { "\(kind)-\(position)-\(rule)" }
        public let kind: Kind
        /// 1-based position in the new rules (added) or old rules (removed).
        public let position: Int
        public let rule: String
        public let type: String
        public let payload: String
        public let target: String
    }

    public let groupsAdded: [ProfileAnalysis.Group]
    public let groupsRemoved: [String]
    public let groupsChanged: [GroupChange]
    public let rules: [RuleChange]
    public let providersAdded: [String]
    public let providersRemoved: [String]
    /// The new configuration's analysis, for member details (types, counts).
    public let after: ProfileAnalysis?

    public var isEmpty: Bool {
        groupsAdded.isEmpty && groupsRemoved.isEmpty && groupsChanged.isEmpty && rules.isEmpty && providersAdded.isEmpty && providersRemoved.isEmpty
    }

    public static func compute(old: String, new: String) -> ConfigDiff {
        let before = ProfileAnalysis.analyze(old), after = ProfileAnalysis.analyze(new)
        let oldGroups = Dictionary((before?.groups ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newGroups = Dictionary((after?.groups ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let added = (after?.groups ?? []).filter { oldGroups[$0.name] == nil }
        let removed = (before?.groups ?? []).filter { newGroups[$0.name] == nil }.map(\.name)
        var changed: [GroupChange] = []
        for group in after?.groups ?? [] {
            guard let previous = oldGroups[group.name] else { continue }
            let oldMembers = previous.members.map(\.name), newMembers = group.members.map(\.name)
            if oldMembers != newMembers || previous.type != group.type {
                changed.append(GroupChange(name: group.name, oldType: previous.type, newType: group.type,
                                           added: newMembers.filter { !oldMembers.contains($0) }, removed: oldMembers.filter { !newMembers.contains($0) }))
            }
        }

        let oldDoc = try? ConfigDocument.parse(old), newDoc = try? ConfigDocument.parse(new)
        let oldRules = oldDoc?.rules ?? [], newRules = newDoc?.rules ?? []
        var rules: [RuleChange] = []
        let lines = LineDiff.diff(oldRules.joined(separator: "\n"), newRules.joined(separator: "\n"))
        for line in lines where line.kind != .same {
            let parsed = RuleParts.parse(line.text)
            rules.append(RuleChange(kind: line.kind == .added ? .added : .removed,
                                    position: (line.kind == .added ? line.newNumber : line.oldNumber) ?? 0,
                                    rule: line.text, type: parsed?.type ?? String(line.text.prefix { $0 != "," }),
                                    payload: parsed?.payload ?? "", target: parsed?.target ?? ""))
        }
        let oldProviders = Set(oldDoc?.providers.map(\.key) ?? []), newProviders = newDoc?.providers.map(\.key) ?? []
        return ConfigDiff(groupsAdded: added, groupsRemoved: removed, groupsChanged: changed, rules: rules,
                          providersAdded: newProviders.filter { !oldProviders.contains($0) },
                          providersRemoved: (oldDoc?.providers.map(\.key) ?? []).filter { !newProviders.contains($0) },
                          after: after)
    }
}
