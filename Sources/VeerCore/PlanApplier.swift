import Foundation
import Yams

/// One reviewable change produced from one plan operation.
public struct ChangeItem: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable { case route, removeRule, ruleSet, group }

    /// A proxy group the plan creates.
    public struct GroupInfo: Sendable, Codable, Hashable {
        public let name: String
        public let type: String
        public let members: [String]
        /// Member count per region display name, for the review card.
        public let regionCounts: [String: Int]
        /// Excluded region names, for the review card.
        public var excluded: [String]? = nil
    }

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
    public var group: GroupInfo?
}

public struct ApplyResult: Sendable {
    public let candidate: String
    public let items: [ChangeItem]
    public let changed: Bool
}

public enum PlanApplier {
    /// Applies the accepted operations of `plan` to `base`. Throws with a user-facing reason when
    /// the plan is invalid or the result would change anything outside `rules`/new providers.
    public static func apply(_ plan: EditPlan, to base: ConfigDocument, regions: [String: Region] = [:], accepting accepted: Set<Int>? = nil,
                             verification: [String: RuleSetVerification] = [:]) throws -> ApplyResult {
        guard (1...32).contains(plan.operations.count) else { throw EditorError("修改计划需要 1 到 32 项操作。") }
        func isAccepted(_ index: Int) -> Bool { accepted?.contains(index) ?? true }

        // 0. New groups: members come from Veer's own region data (user corrections first), never
        //    from model-supplied names. Each gets a name that does not collide with existing exits.
        var takenNames = Set(base.targets.map(\.name))
        var newGroups: [String: (index: Int, name: String)] = [:]
        var groupItems: [Int: ChangeItem] = [:]
        var groupAdditions: [(name: String, type: String, members: [String])] = []
        func region(of name: String) -> Region { regions[name] ?? Region.infer(from: name) }
        for (index, op) in plan.operations.enumerated() {
            guard case let .group(spec) = op else { continue }
            guard newGroups[spec.id] == nil else { throw EditorError("计划里有重复的新策略组 id：\(spec.id)") }
            var members: [String] = []
            for id in spec.members {
                guard let target = base.target(id: id) else { throw EditorError("新策略组引用了当前配置中不存在的出口。") }
                if !members.contains(target.name) { members.append(target.name) }
            }
            if !spec.regions.isEmpty || !spec.excludeRegions.isEmpty {
                // Prefer the config's own regional groups (台湾自动, 香港节点 …), in the order of the
                // requested regions; fall back to individual nodes when there are none. With only
                // exclusions, every known region except those (unknown-region exits are left out,
                // since they might be in an excluded region).
                let excluded = Set(spec.excludeRegions)
                let wanted = spec.regions.isEmpty
                    ? Region.allCases.filter { $0 != .unknown && !excluded.contains($0) }
                    : spec.regions.filter { !excluded.contains($0) }
                func inRegions(_ kind: Target.Kind) -> [String] {
                    wanted.flatMap { place in base.targets.filter { $0.kind == kind && region(of: $0.name) == place }.map(\.name) }
                }
                var regional = inRegions(.group)
                if regional.isEmpty { regional = inRegions(.node) }
                guard !regional.isEmpty else {
                    let description = spec.regions.isEmpty ? "除\(spec.excludeRegions.map(\.displayName).joined(separator: "、"))以外地区" : spec.regions.map(\.displayName).joined(separator: "、")
                    throw EditorError("当前配置里没有标记为\(description)的节点或策略组，无法新建“\(spec.name)”。可以在检查器的“出口”里更正地区。")
                }
                for name in regional where !members.contains(name) { members.append(name) }
            }
            var name = spec.name, suffix = 2
            while takenNames.contains(name) { name = "\(spec.name) \(suffix)"; suffix += 1 }
            takenNames.insert(name)
            newGroups[spec.id] = (index, name)
            var counts: [String: Int] = [:]
            for member in members { counts[region(of: member) == .unknown ? "未指定地区" : region(of: member).displayName, default: 0] += 1 }
            groupItems[index] = ChangeItem(id: index, kind: .group, subject: name, matchType: "", match: "", targetName: nil, targetID: spec.id,
                                           replaced: [], rule: nil, provider: nil,
                                           group: .init(name: name, type: spec.type, members: members, regionCounts: counts,
                                                        excluded: spec.excludeRegions.isEmpty ? nil : spec.excludeRegions.map(\.displayName)))
            if isAccepted(index) { groupAdditions.append((name, spec.type, members)) }
        }

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
            case .group:
                items.append(groupItems[index]!)
                continue
            }
            if case .ruleSet = op {} else { try MatchValidator.validate(type: matchType, match: match, removing: targetID == nil) }
            let prefix = "\(matchType),\(match),".lowercased()
            guard touched.insert(prefix).inserted else { throw EditorError("计划对 \(match) 有重复或冲突的修改，请拆分指令。") }
            let replaced = base.rules.enumerated().filter { lowerRules[$0.offset].hasPrefix(prefix) }.map(\.element)

            var target: Target?
            if let targetID {
                if let created = newGroups[targetID] {
                    if isAccepted(index) && !isAccepted(created.index) {
                        throw EditorError("“\(match)”指向新策略组“\(created.name)”，请同时接受新建该策略组。")
                    }
                    target = Target(id: targetID, name: created.name, kind: .group, type: nil)
                } else {
                    guard let found = base.target(id: targetID) else { throw EditorError("修改引用了当前配置中不存在的出口。") }
                    target = found
                }
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

        let active = items.filter { isAccepted($0.id) && $0.kind != .group }

        // 3. Add new rule providers used by accepted items, then re-read the intermediate text.
        var additions: [(key: String, fields: [(String, String)])] = []
        for item in active {
            if let placed = specs[item.id], let fields = placed.fields, !additions.contains(where: { $0.key == placed.key }) {
                additions.append((placed.key, fields))
            }
        }
        var lines = SourceLines(base.text)
        try YAMLSplice.addProviders(in: &lines, document: base, additions: additions)
        var intermediate = additions.isEmpty ? base : try ConfigDocument.parse(lines.text)
        if !groupAdditions.isEmpty {
            lines = SourceLines(intermediate.text)
            try YAMLSplice.addGroups(in: &lines, document: intermediate, additions: groupAdditions)
            intermediate = try ConfigDocument.parse(lines.text)
        }
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
        try verify(original: base, candidate: candidate, expectedRules: final.map(\.rule), addedProviders: additions.map(\.key),
                   addedGroups: groupAdditions)
        return ApplyResult(candidate: candidate, items: items, changed: candidate != base.text)
    }

    static func verify(original: ConfigDocument, candidate: String, expectedRules: [String], addedProviders: [String],
                       addedGroups: [(name: String, type: String, members: [String])] = []) throws {
        let reread: ConfigDocument
        do { reread = try ConfigDocument.parse(candidate) } catch {
            throw EditorError("生成的配置无法重新解析，已拒绝：\((error as? EditorError)?.message ?? "")")
        }
        guard reread.rules == expectedRules else { throw EditorError("序列化后的规则与计划不一致，已拒绝生成。") }
        guard let before = try compose(yaml: original.text)?.mapping, let after = try compose(yaml: candidate)?.mapping else {
            throw EditorError("生成的配置无法重新解析，已拒绝。")
        }
        let editable: Set<String> = ["rules", "rule-providers", "proxy-groups"]
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

        // proxy-groups: every existing group unchanged and in place; only the planned groups appended.
        let oldGroups = before["proxy-groups"]?.sequence.map(Array.init) ?? []
        let newGroups = after["proxy-groups"]?.sequence.map(Array.init) ?? []
        guard newGroups.count == oldGroups.count + addedGroups.count, Array(newGroups.prefix(oldGroups.count)) == oldGroups else {
            throw EditorError("修改会改变已有的策略组，已拒绝生成。")
        }
        for (node, expected) in zip(newGroups.dropFirst(oldGroups.count), addedGroups) {
            guard let map = node.mapping, map["name"]?.string == expected.name, map["type"]?.string == expected.type,
                  map["proxies"]?.sequence?.compactMap(\.string) == expected.members else {
                throw EditorError("新建的策略组与计划不一致，已拒绝生成。")
            }
        }
    }
}
