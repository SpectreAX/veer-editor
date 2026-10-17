import Foundation

/// Deterministic parsing of common instructions, used without an AI service.
public enum LocalIntentParser {
    /// Services with a known MetaCubeX geosite set.
    static let services: [(pattern: String, geosite: String)] = [
        (#"netflix|奈飞|网飞"#, "netflix"),
        (#"chatgpt|openai"#, "openai"),
        (#"youtube|油管"#, "youtube"),
        (#"telegram|电报|\btg\b"#, "telegram"),
        (#"google|谷歌"#, "google"),
        (#"github"#, "github"),
        (#"spotify"#, "spotify"),
        (#"tiktok|抖音国际"#, "tiktok"),
        (#"claude|anthropic"#, "anthropic"),
        (#"disney"#, "disney"),
        (#"广告|\bads?\b"#, "category-ads-all"),
    ]

    static let outOfScopePattern = #"延迟|太卡|很卡|卡顿|最快|测速|ping|latency|slow|fastest|换个?节点|换一个|切换节点|开启?vpn|启动vpn|关闭vpn|连接代理|断开"#

    public static let outOfScopeMessage = "我只编辑分流规则，不能测速、启动 VPN 或切换运行中的节点。你可以指定一个出口，例如“YouTube 走香港”。"

    /// True when the instruction asks for something outside rule editing. Checked before any AI call.
    public static func isOutOfScope(_ prompt: String) -> Bool { prompt.matches(outOfScopePattern) }

    public static func parse(_ prompt: String, targets: [Target], regions: [String: Region]) throws -> AssistantReply {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorError("请输入希望修改的分流，例如“Netflix 走日本”。") }
        if isOutOfScope(trimmed) { return .outOfScope(outOfScopeMessage) }

        let exits = targets.filter { $0.kind != .builtin }
        let suggestions = Array(exits.filter { $0.kind == .group }.prefix(4).map(\.name))
        var operations: [EditPlan.Operation] = []
        for clause in clauses(trimmed, exitNames: exits.map(\.name)) {
            if clause.matches(#"不要|不走|别走|别用|不使用|除了|除外|except|unless|\bnot\b|don't"#) {
                throw EditorError("本地解析不支持否定或例外条件。请改用明确的正向指令，或切换到 AI 解析。")
            }
            // Strip exit names before looking for domains so names like "hk.example" don't count.
            var scan = clause
            for name in exits.map(\.name).sorted(by: { $0.count > $1.count }) { scan = scan.replacingOccurrences(of: name, with: " ") }
            let domains = matchesOf(#"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b"#, in: scan).map { $0.lowercased() }
            let geosites = domains.isEmpty ? services.filter { scan.matches($0.pattern) }.map(\.geosite) : []
            guard !domains.isEmpty || !geosites.isEmpty else {
                throw EditorError("本地解析只认识常见服务（Netflix、ChatGPT、YouTube、Telegram、Google、GitHub、Spotify、TikTok、Claude、Disney+、广告）和明确域名。其他说法请切换到 AI 解析。")
            }

            if clause.matches(#"删除|移除|去掉|remove|delete"#) {
                for domain in domains { operations.append(.removeRule(matchType: "DOMAIN-SUFFIX", match: domain)) }
                if !geosites.isEmpty { throw EditorError("本地解析只能删除明确域名的规则，例如“删除 example.com 的规则”。") }
                continue
            }

            let target: Target
            switch try resolveExit(clause, targets: targets, regions: regions, defaultReject: geosites == ["category-ads-all"]) {
            case .target(let found): target = found
            case .ask(let question, let options):
                return .clarification(question, suggestions: options.isEmpty ? suggestions : options)
            }
            for domain in domains { operations.append(.route(matchType: "DOMAIN-SUFFIX", match: domain, targetId: target.id)) }
            for geosite in geosites {
                operations.append(.ruleSet(.catalog(source: "metacubex-geosite", name: geosite), targetId: target.id))
            }
        }
        guard !operations.isEmpty else { throw EditorError("没有识别到可执行的修改。") }
        guard operations.count <= 32 else { throw EditorError("一次最多 32 项修改，请拆分指令。") }
        return .plan(EditPlan(operations: operations))
    }

    enum ExitResolution { case target(Target), ask(String, [String]) }

    static func resolveExit(_ clause: String, targets: [Target], regions: [String: Region], defaultReject: Bool) throws -> ExitResolution {
        let exits = targets.filter { $0.kind != .builtin }
        let direct = clause.matches(#"直连|\bdirect\b|不走代理|不代理"#)
        let reject = clause.matches(#"屏蔽|拦截|拒绝|阻止|\breject\b|\bblock\b"#)
        let named = exits.filter { clause.contains($0.name) }
        let longestNamed = named.filter { candidate in !named.contains { $0.name != candidate.name && $0.name.contains(candidate.name) } }
        let asked = Region.allCases.filter { $0.instructionPattern.map(clause.matches) ?? false }

        let actions = (direct ? 1 : 0) + (reject ? 1 : 0) + (longestNamed.isEmpty && asked.isEmpty ? 0 : 1)
        if actions > 1 || longestNamed.count > 1 || asked.count > 1 {
            throw EditorError("同一句里有多个出口或动作，请一次只指定一个方向，或拆成多句。")
        }
        if direct { return .target(targets.first { $0.name == "DIRECT" }!) }
        if reject || (defaultReject && longestNamed.isEmpty && asked.isEmpty) { return .target(targets.first { $0.name == "REJECT" }!) }
        if let only = longestNamed.first { return .target(only) }
        guard let region = asked.first else {
            return .ask(SystemPrompt.askForExit, [])
        }
        let regional = exits.filter { (regions[$0.name] ?? .unknown) == region }
        let groups = regional.filter { $0.kind == .group }
        let pool = groups.isEmpty ? regional : groups
        if pool.count == 1 { return .target(pool[0]) }
        if pool.isEmpty {
            return .ask("当前配置里没有标记为\(region.displayName)的出口。请选择一个出口，或在检查器的“出口”里更正地区。", [])
        }
        return .ask("有 \(pool.count) 个\(region.displayName)出口，请选择一个：", Array(pool.prefix(6).map(\.name)))
    }

    /// Splits on separators, but never inside an exit name.
    static func clauses(_ prompt: String, exitNames: [String]) -> [String] {
        var protected = prompt
        var placeholders: [String: String] = [:]
        for (index, name) in exitNames.sorted(by: { $0.count > $1.count }).enumerated() where protected.contains(name) {
            let token = "\u{E000}\(index)\u{E001}"
            placeholders[token] = name
            protected = protected.replacingOccurrences(of: name, with: token)
        }
        let parts = protected.components(separatedBy: CharacterSet(charactersIn: "\n;；,，、。"))
            .flatMap { $0.components(separatedBy: "同时") }
            .flatMap { $0.components(separatedBy: "并且") }
            .flatMap { $0.replacingOccurrences(of: #"\s+and\s+"#, with: "\u{E002}", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\u{E002}") }
        return parts.map { part in
            var restored = part
            for (token, name) in placeholders { restored = restored.replacingOccurrences(of: token, with: name) }
            return restored.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    static func matchesOf(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
