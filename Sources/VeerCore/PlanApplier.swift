import Foundation
import Yams

/// One reviewable change produced from one plan operation.
public struct ChangeItem: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case route, removeRule, ruleSet }

    public struct ProviderInfo: Sendable, Codable, Hashable {
        public let key: String
        public let url: String
        public let behavior: String
        public let format: String
        public let sourceLabel: String
        public let reused: Bool
        public var verification: RuleSetVerification
    }

    /// Index of the operation in the plan.
    public let id: Int
    public let kind: Kind
    /// What the user recognizes: "Netflix", "example.com".
    public let subject: String
    public let matchType: String
    public let match: String
    public let targetName: String?
    public let targetID: String?
    /// Existing rules this change replaces or removes.
    public let replaced: [String]
    /// The rule written, or nil for a removal.
    public let rule: String?
    public var provider: ProviderInfo?
}

public struct ApplyResult: Sendable {
    public let candidate: String
    public let items: [ChangeItem]
    public let changed: Bool
}

public enum PlanApplier {
    /// Applies the accepted operations of `plan` to `base`. Throws with a user-facing reason when
    /// the plan is invalid or the result would change anything outside `rules`/new providers.
    public static func apply(_ plan: EditPlan, to base: ConfigDocument, accepting accepted: Set<Int>? = nil,
                             verification: [String: RuleSetVerification] = [:]) throws -> ApplyResult {
        guard (1...32).contains(plan.operations.count) else { throw EditorError("修改计划需要 1 到 32 项操作。") }

        // 1. Resolve rule sets: reuse a provider with the same URL or reserve a free key.
        var existingProviders: [String: String?] = Dictionary(base.providers.map { ($0.key, $0.url) }, uniquingKeysWith: { first, _ in first })
        var specs: [Int: (spec: RuleSetCatalog.Spec, key: String, reused: Bool, fields: [(String, String)]?)] = [:]
        for (index, op) in plan.operations.enumerated() {
            guard case let .ruleSet(reference, _) = op else { continue }
            let spec = try RuleSetCatalog.spec(for: reference)
            let place = RuleSetCatalog.place(spec, existing: existingProviders)
            if !place.reused { existingProviders[place.key] = spec.url }
            specs[index] = (spec, place.key, place.reused, place.provider)
        }

        // 2. Validate every operation and build the items, even rejected ones, so the UI can list them.
        var items: [ChangeItem] = []
        var touched = Set<String>()
        let lowerRules = base.rules.map { $0.lowercased() }
        for (index, op) in plan.operations.enumerated() {
            let matchType: String, match: String, targetID: String?
            switch op {
            case let .route(type, value, target): (matchType, match, targetID) = (type, value, target)
            case let .removeRule(type, value): (matchType, match, targetID) = (type, value, nil)
            case let .ruleSet(_, target): (matchType, match, targetID) = ("RULE-SET", specs[index]!.key, target)
            }
            if case .ruleSet = op {} else { try MatchValidator.validate(type: matchType, match: match) }
            let prefix = "\(matchType),\(match),".lowercased()
            guard touched.insert(prefix).inserted else { throw EditorError("计划对 \(match) 有重复或冲突的修改，请拆分指令。") }
            let replaced = base.rules.enumerated().filter { lowerRules[$0.offset].hasPrefix(prefix) }.map(\.element)

            var target: Target?
            if let targetID {
                guard let found = base.target(id: targetID) else { throw EditorError("AI 引用了当前配置中不存在的出口。") }
                target = found
            }
            var rule: String?
            if let target {
                let keepNoResolve = ["IP-CIDR", "IP-CIDR6", "GEOIP"].contains(matchType) && replaced.contains { $0.hasSuffix(",no-resolve") }
                rule = "\(matchType),\(match),\(target.name)\(keepNoResolve ? ",no-resolve" : "")"
            } else if replaced.isEmpty, accepted?.contains(index) ?? true {
                throw EditorError("配置中没有 \(matchType),\(match) 这条规则，没有可删除的内容。")
            }

            var provider: ChangeItem.ProviderInfo?
            var subject = match
            var kind: ChangeItem.Kind = targetID == nil ? .removeRule : .route
            if let placed = specs[index] {
                kind = .ruleSet
                subject = placed.spec.serviceName
                provider = .init(key: placed.key, url: placed.spec.url, behavior: placed.spec.behavior, format: placed.spec.format,
                                 sourceLabel: placed.spec.sourceLabel, reused: placed.reused,
                                 verification: placed.reused ? .reused : verification[placed.spec.url] ?? .unverified)
            }
            items.append(ChangeItem(id: index, kind: kind, subject: subject, matchType: matchType, match: match,
                                    targetName: target?.name, targetID: targetID, replaced: replaced, rule: rule, provider: provider))
        }

        let active = items.filter { accepted?.contains($0.id) ?? true }

        // 3. Add new rule providers used by accepted items, then re-read the intermediate text.
        var additions: [(key: String, fields: [(String, String)])] = []
        for item in active {
            if let placed = specs[item.id], let fields = placed.fields, !additions.contains(where: { $0.key == placed.key }) {
                additions.append((placed.key, fields))
            }
        }
        var lines = SourceLines(base.text)
        try YAMLSplice.addProviders(in: &lines, document: base, additions: additions)
        let intermediate = additions.isEmpty ? base : try ConfigDocument.parse(lines.text)
        lines = SourceLines(intermediate.text)

        // 4. Rules: accepted additions go to the top in plan order, then every untouched original.
        let removedPrefixes = active.map { "\($0.matchType),\($0.match),".lowercased() }
        var final: [(rule: String, original: Int?, inheritComments: Int?)] = []
        for item in active {
            guard let rule = item.rule else { continue }
            let firstReplaced = intermediate.rules.firstIndex { $0 == item.replaced.first }
            final.append((rule, nil, firstReplaced))
        }
        for (index, rule) in intermediate.rules.enumerated() where !removedPrefixes.contains(where: { rule.lowercased().hasPrefix($0) }) {
            final.append((rule, index, nil))
        }
        YAMLSplice.replaceRules(in: &lines, document: intermediate, final: final)
        let candidate = lines.text

        // 5. Prove the edit stayed inside its boundary.
        try verify(original: base, candidate: candidate, expectedRules: final.map(\.rule), addedProviders: additions.map(\.key))
        return ApplyResult(candidate: candidate, items: items, changed: candidate != base.text)
    }

    static func verify(original: ConfigDocument, candidate: String, expectedRules: [String], addedProviders: [String]) throws {
        let reread: ConfigDocument
        do { reread = try ConfigDocument.parse(candidate) } catch {
            throw EditorError("生成的配置无法重新解析，已拒绝：\((error as? EditorError)?.message ?? "")")
        }
        guard reread.rules == expectedRules else { throw EditorError("序列化后的规则与计划不一致，已拒绝生成。") }
        guard let before = try compose(yaml: original.text)?.mapping, let after = try compose(yaml: candidate)?.mapping else {
            throw EditorError("生成的配置无法重新解析，已拒绝。")
        }
        let editable: Set<String> = ["rules", "rule-providers"]
        let beforeKeys = Array(before.keys).compactMap(\.string).filter { !editable.contains($0) }
        let afterKeys = Array(after.keys).compactMap(\.string).filter { !editable.contains($0) }
        guard beforeKeys == afterKeys, beforeKeys.allSatisfy({ before[$0] == after[$0] }) else {
            throw EditorError("修改会改变规则以外的配置字段，已拒绝生成。")
        }
        let oldProviders = before["rule-providers"]?.mapping
        let newProviders = after["rule-providers"]?.mapping
        for (key, value) in oldProviders ?? [:] {
            guard newProviders?[key] == value else { throw EditorError("修改会改变已有的规则集，已拒绝生成。") }
        }
        let added = (newProviders.map { Array($0.keys).compactMap(\.string) } ?? []).filter { key in !(oldProviders?.keys.contains { $0.string == key } ?? false) }
        guard Set(added) == Set(addedProviders) else { throw EditorError("新增的规则集与计划不一致，已拒绝生成。") }
    }
}
