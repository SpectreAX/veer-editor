import Foundation

/// Clean-up applied to the proxies of a configuration that Veer generates from a subscription.
/// A user's full Mihomo YAML is never passed through here: the editor only edits its rules.
public struct ImportOptions: Sendable, Equatable {
    /// Drops pseudo-nodes whose names only announce remaining traffic, expiry or a website.
    public var removeInfoNodes = true
    /// Drops nodes whose settings equal an earlier node's, apart from the name.
    public var removeDuplicates = true
    /// Prefixes the region flag to names that lack one. Off by default: it renames nodes.
    public var addRegionFlags = false

    public init(removeInfoNodes: Bool = true, removeDuplicates: Bool = true, addRegionFlags: Bool = false) {
        self.removeInfoNodes = removeInfoNodes
        self.removeDuplicates = removeDuplicates
        self.addRegionFlags = addRegionFlags
    }
}

/// What the clean-up changed, reported in the import note.
public struct CleanupReport: Sendable, Equatable {
    public var infoNodes: [String] = []
    /// Names of the removed copies; the first node with the same settings is kept.
    public var duplicates: [String] = []
    public var flagged = 0

    public init(infoNodes: [String] = [], duplicates: [String] = [], flagged: Int = 0) {
        self.infoNodes = infoNodes
        self.duplicates = duplicates
        self.flagged = flagged
    }

    public var isEmpty: Bool { infoNodes.isEmpty && duplicates.isEmpty && flagged == 0 }

    public var summary: String? {
        var parts: [String] = []
        if !infoNodes.isEmpty { parts.append("已移除 \(infoNodes.count) 个信息节点（\(Self.sample(infoNodes))）") }
        if !duplicates.isEmpty { parts.append("\(parts.isEmpty ? "已移除 " : "")\(duplicates.count) 个重复节点") }
        if flagged > 0 { parts.append("为 \(flagged) 个节点添加了地区旗帜") }
        return parts.isEmpty ? nil : parts.joined(separator: "、") + "。"
    }

    static func sample(_ names: [String]) -> String {
        let shown = names.prefix(3).map { "“\($0)”" }.joined(separator: "、")
        return names.count > 3 ? shown + " 等" : shown
    }
}

enum NodeCleanup {
    /// Phrases that only appear in notices a provider disguises as nodes. Kept specific on
    /// purpose: real node names often carry rates ("0.5x") or plan tiers, which must stay.
    static let infoPhrases = [
        "剩余流量", "已用流量", "总流量", "流量重置", "重置流量", "下次重置", "距离重置",
        "到期", "过期", "有效期", "套餐", "官网", "网址", "发布页", "最新地址", "防失联",
        "续费", "客服", "交流群", "电报群", "tg群", "公告", "使用说明",
        "expire", "expiry", "expiration", "traffic", "remaining",
        "website", "homepage", "renew", "telegram", "t.me/",
    ]

    /// Amounts such as "12.5 GB" and dates such as "2026-12-31" mark usage or expiry notices.
    static let infoPatterns = [
        #"\d+(\.\d+)?\s*(KB|MB|GB|TB)\b"#,
        #"\b(19|20)\d{2}[-/.年]\d{1,2}[-/.月]\d{1,2}"#,
    ]

    static func isInfoNode(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if infoPhrases.contains(where: { lowered.contains($0) }) { return true }
        return infoPatterns.contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Settings of a node apart from its name, with map keys sorted and scalars compared as text,
    /// so `port: 443` and `port: "443"` are the same node.
    static func fingerprint(_ proxy: YAMLValue) -> String {
        guard case .map(let pairs) = proxy else { return canonical(proxy) }
        return canonical(.map(pairs.filter { $0.0 != "name" }.map { key, value in
            key == "server" ? (key, .string((value.stringValue ?? canonical(value)).lowercased())) : (key, value)
        }))
    }

    static func canonical(_ value: YAMLValue) -> String {
        switch value {
        case .string(let s): s.debugDescription
        case .int(let i): String(i).debugDescription
        case .bool(let b): (b ? "true" : "false").debugDescription
        case .list(let items): "[" + items.map(canonical).joined(separator: ",") + "]"
        case .map(let pairs): "{" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0.debugDescription):\(canonical($0.1))" }.joined(separator: ",") + "}"
        }
    }

    static func hasFlag(_ name: String) -> Bool {
        name.unicodeScalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) }
    }

    static func flag(for region: Region) -> String? {
        guard region != .unknown else { return nil }
        let scalars = region.rawValue.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `proxies` are (cleaned name, node) pairs in subscription order.
    static func apply(_ proxies: [(String, YAMLValue)], options: ImportOptions) throws -> ([(String, YAMLValue)], CleanupReport) {
        var report = CleanupReport()
        var kept = proxies
        if options.removeInfoNodes {
            let info = kept.filter { isInfoNode($0.0) }
            if info.count == kept.count, !kept.isEmpty {
                throw EditorError("订阅里只有流量、到期或官网提示，没有可用节点。订阅可能已过期或流量已用完，请到服务商处续费后再导入。")
            }
            report.infoNodes = info.map(\.0)
            kept.removeAll { isInfoNode($0.0) }
        }
        if options.removeDuplicates {
            var seen = Set<String>()
            kept = kept.filter { name, proxy in
                if seen.insert(fingerprint(proxy)).inserted { return true }
                report.duplicates.append(name)
                return false
            }
        }
        if options.addRegionFlags {
            kept = kept.map { name, proxy in
                // A notice kept on purpose gets no flag: "12 GB" would otherwise read as Britain.
                guard !hasFlag(name), !isInfoNode(name), let flag = flag(for: Region.infer(from: name)) else { return (name, proxy) }
                report.flagged += 1
                return ("\(flag) \(name)", proxy)
            }
        }
        return (kept, report)
    }
}
