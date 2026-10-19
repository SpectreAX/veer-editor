import Foundation

/// The structured plan (schema v1) shared with the Android client and the earlier editor
/// service. The model only proposes; deterministic code validates and applies.
public struct EditPlan: Codable, Sendable, Hashable {
    public static let matchTypes: [String] = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOSITE", "GEOIP"]

    public enum Operation: Codable, Sendable, Hashable {
        case route(matchType: String, match: String, targetId: String)
        case removeRule(matchType: String, match: String)
        case ruleSet(RuleSetReference, targetId: String)
        /// A new proxy group appended to `proxy-groups`. Other operations in the same plan can
        /// target it by `NewGroup.id` (e.g. "new-1").
        case group(NewGroup)
    }

    /// One group to create. Members come from `regions` (nodes Veer has tagged with those
    /// regions, falling back to regional groups) and/or explicit existing target ids.
    public struct NewGroup: Codable, Sendable, Hashable {
        public static let types = ["select", "url-test", "fallback"]
        public let id: String
        public let name: String
        public let type: String
        public let regions: [Region]
        public let members: [String]
        /// Regions to leave out. Alone, it means "every known region except these"
        /// (e.g. AI services excluding Hong Kong and Macau).
        public let excludeRegions: [Region]

        public init(id: String, name: String, type: String = "select", regions: [Region] = [], members: [String] = [], excludeRegions: [Region] = []) {
            self.id = id
            self.name = name
            self.type = type
            self.regions = regions
            self.members = members
            self.excludeRegions = excludeRegions
        }

        enum CodingKeys: String, CodingKey { case id, name, type, regions, members, excludeRegions }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(String.self, forKey: .type)
            regions = try container.decode([Region].self, forKey: .regions)
            members = try container.decode([String].self, forKey: .members)
            // Sessions saved before 2026-10-18 have no exclusions.
            excludeRegions = try container.decodeIfPresent([Region].self, forKey: .excludeRegions) ?? []
        }
    }

    public var operations: [Operation]
    public init(operations: [Operation]) { self.operations = operations }
}

public enum RuleSetReference: Codable, Sendable, Hashable {
    case catalog(source: String, name: String)
    case url(String, behavior: String?)
}

/// One answer offered with a clarification. `prompt` is the complete instruction to send when
/// chosen; nil means "send a short follow-up naming this exit" (the AI resolves it from history).
public struct ClarifyOption: Codable, Sendable, Hashable {
    public let label: String
    public let prompt: String?
    public init(label: String, prompt: String? = nil) {
        self.label = label
        self.prompt = prompt
    }
}

/// What the assistant answered for one instruction.
public enum AssistantReply: Sendable, Equatable {
    case plan(EditPlan)
    case clarification(String, options: [ClarifyOption])
    case outOfScope(String)
}

extension EditPlan {
    /// Strictly decodes a model reply. Unknown fields, mixed clarification/plan replies and
    /// malformed operations are rejected rather than repaired.
    public static func decodeReply(_ content: String) throws -> AssistantReply {
        try decodeReplyWithUnderstanding(content).reply
    }

    /// Also returns the model's one-line `understanding` (how it read the instruction), if given.
    public static func decodeReplyWithUnderstanding(_ content: String) throws -> (reply: AssistantReply, understanding: String?) {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        // Reasoning models sometimes add prose around the JSON; fall back to the outermost object.
        if (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil,
           let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            text = String(text[open...close])
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw EditorError("AI 没有返回有效的结构化计划，请换一种说法再试。")
        }
        let understanding = (root["understanding"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }
        if let clarification = root["clarification"] {
            guard Set(root.keys).isSubset(of: ["clarification", "understanding"]), let question = clarification as? String,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError("AI 同时返回了问题和修改，已拒绝。请重新生成。")
            }
            return (.clarification(String(question.prefix(500)), options: []), understanding)
        }
        guard Set(root.keys).isSubset(of: ["schemaVersion", "operations", "understanding"]),
              (root["schemaVersion"] as? NSNumber)?.intValue == 1,
              let rawOperations = root["operations"] as? [Any],
              (1...32).contains(rawOperations.count) else {
            throw EditorError("AI 返回的修改计划格式无效，请重新生成。")
        }
        return (.plan(EditPlan(operations: try rawOperations.map(decodeOperation))), understanding)
    }

    static func decodeOperation(_ raw: Any) throws -> Operation {
        guard let op = raw as? [String: Any], let kind = op["kind"] as? String else {
            throw EditorError("AI 返回了无效的规则操作。")
        }
        func fields(_ allowed: Set<String>) throws {
            guard Set(op.keys).isSubset(of: allowed) else { throw EditorError("AI 的规则操作包含不支持的字段，请重新生成。") }
        }
        func string(_ key: String) throws -> String {
            guard let value = op[key] as? String else { throw EditorError("AI 的规则操作缺少 \(key)。") }
            return value
        }
        switch kind {
        case "route":
            try fields(["kind", "matchType", "match", "targetId"])
            return .route(matchType: try string("matchType").uppercased(), match: try string("match"), targetId: try string("targetId"))
        case "remove_rule":
            try fields(["kind", "matchType", "match"])
            return .removeRule(matchType: try string("matchType").uppercased(), match: try string("match"))
        case "group":
            try fields(["kind", "id", "name", "type", "regions", "members", "excludeRegions"])
            let id = try string("id"), name = try string("name").trimmingCharacters(in: .whitespaces)
            let type = (op["type"] as? String ?? "select").lowercased()
            guard id.range(of: #"^new-[0-9]{1,2}$"#, options: .regularExpression) != nil else { throw EditorError("新策略组的 id 必须是 new-1、new-2 这样的形式。") }
            guard !name.isEmpty, name.count <= 64, name.rangeOfCharacter(from: CharacterSet(charactersIn: ",\r\n")) == nil else {
                throw EditorError("新策略组的名称为空、过长或包含逗号。")
            }
            guard NewGroup.types.contains(type) else { throw EditorError("新策略组只支持 select、url-test 或 fallback。") }
            func regionList(_ key: String) throws -> [Region] {
                try (op[key] as? [String] ?? []).map { code -> Region in
                    guard let region = Region(rawValue: code.uppercased()), region != .unknown else { throw EditorError("不支持的地区代码：\(code.prefix(10))") }
                    return region
                }
            }
            let regions = try regionList("regions"), excluded = try regionList("excludeRegions")
            let members = op["members"] as? [String] ?? []
            guard !regions.isEmpty || !members.isEmpty || !excluded.isEmpty else { throw EditorError("新策略组需要 regions、excludeRegions 或 members。") }
            return .group(NewGroup(id: id, name: name, type: type, regions: regions, members: members, excludeRegions: excluded))
        case "rule_set":
            if op["url"] != nil {
                try fields(["kind", "url", "behavior", "targetId"])
                return .ruleSet(.url(try string("url"), behavior: op["behavior"] as? String), targetId: try string("targetId"))
            }
            try fields(["kind", "source", "name", "targetId"])
            return .ruleSet(.catalog(source: try string("source"), name: try string("name")), targetId: try string("targetId"))
        default:
            throw EditorError("目前只支持添加、修改、删除分流规则，添加规则集和新建策略组（收到 \(kind.prefix(30))）。")
        }
    }

    /// JSON form, used for anonymized history and tests.
    public var jsonObject: [String: Any] {
        ["schemaVersion": 1, "operations": operations.map { op -> [String: Any] in
            switch op {
            case let .route(matchType, match, targetId):
                return ["kind": "route", "matchType": matchType, "match": match, "targetId": targetId]
            case let .removeRule(matchType, match):
                return ["kind": "remove_rule", "matchType": matchType, "match": match]
            case let .ruleSet(.catalog(source, name), targetId):
                return ["kind": "rule_set", "source": source, "name": name, "targetId": targetId]
            case let .group(group):
                var object: [String: Any] = ["kind": "group", "id": group.id, "name": group.name, "type": group.type]
                if !group.regions.isEmpty { object["regions"] = group.regions.map(\.rawValue) }
                if !group.members.isEmpty { object["members"] = group.members }
                if !group.excludeRegions.isEmpty { object["excludeRegions"] = group.excludeRegions.map(\.rawValue) }
                return object
            case let .ruleSet(.url(url, behavior), targetId):
                var object: [String: Any] = ["kind": "rule_set", "url": url, "targetId": targetId]
                if let behavior { object["behavior"] = behavior }
                return object
            }
        }]
    }
}

enum MatchValidator {
    /// `removing`: deletions may also name a rule set (RULE-SET,<provider name>), including the
    /// ones Veer added itself.
    static func validate(type: String, match: String, removing: Bool = false) throws {
        if removing && type == "RULE-SET" {
            guard !match.isEmpty, match.count <= 128, match.rangeOfCharacter(from: CharacterSet(charactersIn: ", \r\n\t")) == nil else {
                throw EditorError("规则集名称为空或包含不允许的字符。")
            }
            return
        }
        guard EditPlan.matchTypes.contains(type) else { throw EditorError("暂不支持修改这类规则：\(type.prefix(30))") }
        guard !match.isEmpty, match.count <= 253, match.rangeOfCharacter(from: CharacterSet(charactersIn: ", \r\n\t")) == nil else {
            throw EditorError("规则匹配值为空或包含不允许的字符。")
        }
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX":
            guard match.matches(#"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]+$"#) else { throw EditorError("域名格式无效：\(match)") }
        case "IP-CIDR", "IP-CIDR6":
            let parts = match.split(separator: "/", omittingEmptySubsequences: false)
            let v6 = type == "IP-CIDR6"
            guard parts.count == 2, let prefix = Int(parts[1]), (0...(v6 ? 128 : 32)).contains(prefix),
                  v6 ? isIPv6(String(parts[0])) : isIPv4(String(parts[0])) else {
                throw EditorError("CIDR 格式无效：\(match)")
            }
        default:
            break
        }
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part), part.count <= 3, (0...255).contains(value) else { return false }
            return !(part.count > 1 && part.hasPrefix("0"))
        }
    }

    static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}
