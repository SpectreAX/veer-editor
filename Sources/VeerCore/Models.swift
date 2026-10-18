import Foundation

/// A user-facing failure. `message` is Chinese UI text and never contains configuration secrets.
public struct EditorError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A rule target: a proxy group, a node, or a built-in policy.
public struct Target: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case group, node, builtin }
    public let id: String
    public let name: String
    public let kind: Kind
    public let type: String?

    public init(id: String, name: String, kind: Kind, type: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.type = type
    }
}

/// Declared or inferred exit region. Never a measured location.
public enum Region: String, CaseIterable, Sendable, Codable {
    case jp = "JP", us = "US", hk = "HK", sg = "SG", tw = "TW", mo = "MO", kr = "KR", gb = "GB", de = "DE", unknown = "UNKNOWN"

    public var displayName: String {
        switch self {
        case .jp: "日本"
        case .us: "美国"
        case .hk: "香港"
        case .sg: "新加坡"
        case .tw: "台湾"
        case .mo: "澳门"
        case .kr: "韩国"
        case .gb: "英国"
        case .de: "德国"
        case .unknown: "未指定"
        }
    }

    /// Matches a region in an exit's own name.
    var namePattern: String? {
        switch self {
        case .jp: #"日本|东京|大阪|\bjp\b|japan|🇯🇵"#
        case .us: #"美国|洛杉矶|纽约|硅谷|\bus\b|\busa\b|united states|🇺🇸"#
        case .hk: #"香港|\bhk\b|hong\s*kong|🇭🇰"#
        case .sg: #"新加坡|狮城|\bsg\b|singapore|🇸🇬"#
        case .tw: #"台湾|台北|\btw\b|taiwan|🇹🇼"#
        case .mo: #"澳门|\bmo\b|macau|macao|🇲🇴"#
        case .kr: #"韩国|首尔|\bkr\b|korea|🇰🇷"#
        case .gb: #"英国|伦敦|\buk\b|\bgb\b|britain|united kingdom|🇬🇧"#
        case .de: #"德国|法兰克福|\bde\b|germany|🇩🇪"#
        case .unknown: nil
        }
    }

    /// Matches a region the user asks for in an instruction.
    var instructionPattern: String? {
        switch self {
        case .jp: #"日本|日区|\bjp\b|\bjapan\b"#
        case .us: #"美国|美区|\bus\b|\busa\b|united states"#
        case .hk: #"香港|港区|港澳|\bhk\b|hong\s*kong"#
        case .sg: #"新加坡|狮城|\bsg\b|singapore"#
        case .tw: #"台湾|台区|\btw\b|taiwan"#
        case .mo: #"澳门|港澳|\bmo\b|macau|macao"#
        case .kr: #"韩国|韩区|\bkr\b|korea"#
        case .gb: #"英国|\buk\b|britain"#
        case .de: #"德国|\bgermany\b"#
        case .unknown: nil
        }
    }

    /// Infers a region from an exit name; ambiguous or absent matches are `.unknown`. Memoized:
    /// large subscriptions call this for hundreds of exits on every render.
    public static func infer(from name: String) -> Region {
        if let cached = InferenceCache.shared.get(name) { return cached }
        let matches = Region.allCases.filter { region in
            guard let pattern = region.namePattern else { return false }
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let region = matches.count == 1 ? matches[0] : .unknown
        InferenceCache.shared.set(name, region)
        return region
    }
}

final class InferenceCache: @unchecked Sendable {
    static let shared = InferenceCache()
    private var values: [String: Region] = [:]
    private let lock = NSLock()

    func get(_ name: String) -> Region? { lock.lock(); defer { lock.unlock() }; return values[name] }

    func set(_ name: String, _ region: Region) {
        lock.lock(); defer { lock.unlock() }
        if values.count > 20_000 { values.removeAll() }
        values[name] = region
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
