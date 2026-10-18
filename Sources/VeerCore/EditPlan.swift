import Foundation

/// The structured plan (schema v1) shared with the Android client and the earlier editor
/// service. The model only proposes; deterministic code validates and applies.
public struct EditPlan: Codable, Sendable, Hashable {
    public static let matchTypes: [String] = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOSITE", "GEOIP"]

    public enum Operation: Codable, Sendable, Hashable {
        case route(matchType: String, match: String, targetId: String)
        case removeRule(matchType: String, match: String)
        case ruleSet(RuleSetReference, targetId: String)
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
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw EditorError("AI 没有返回有效的结构化计划，请换一种说法再试。")
        }
        if let clarification = root["clarification"] {
            guard root.count == 1, let question = clarification as? String,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError("AI 同时返回了问题和修改，已拒绝。请重新生成。")
            }
            return .clarification(String(question.prefix(500)), options: [])
        }
        guard Set(root.keys).isSubset(of: ["schemaVersion", "operations"]),
              (root["schemaVersion"] as? NSNumber)?.intValue == 1,
              let rawOperations = root["operations"] as? [Any],
              (1...32).contains(rawOperations.count) else {
            throw EditorError("AI 返回的修改计划格式无效，请重新生成。")
        }
        return .plan(EditPlan(operations: try rawOperations.map(decodeOperation)))
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
        case "rule_set":
            if op["url"] != nil {
                try fields(["kind", "url", "behavior", "targetId"])
                return .ruleSet(.url(try string("url"), behavior: op["behavior"] as? String), targetId: try string("targetId"))
            }
            try fields(["kind", "source", "name", "targetId"])
            return .ruleSet(.catalog(source: try string("source"), name: try string("name")), targetId: try string("targetId"))
        default:
            throw EditorError("目前只支持添加、修改、删除分流规则和添加规则集（收到 \(kind.prefix(30))）。")
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
            case let .ruleSet(.url(url, behavior), targetId):
                var object: [String: Any] = ["kind": "rule_set", "url": url, "targetId": targetId]
                if let behavior { object["behavior"] = behavior }
                return object
            }
        }]
    }
}

enum MatchValidator {
    static func validate(type: String, match: String) throws {
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
