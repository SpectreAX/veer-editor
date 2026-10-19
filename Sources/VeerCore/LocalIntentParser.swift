import Foundation

/// Deterministic parsing of common instructions, used without an AI service.
public enum LocalIntentParser {
    /// Services with a verified MetaCubeX set. "geoip:" names use the geoip source.
    static let services: [(pattern: String, geosite: String)] = [
        (#"国外\s*ai|ai\s*服务|ai\s*服務|人工智能|^ai\b|\sai\b"#, "category-ai-!cn"),
        (#"gemini"#, "google-gemini"),
        (#"netflix|奈飞|网飞|網飛"#, "netflix"),
        (#"chatgpt|openai"#, "openai"),
        (#"youtube|油管"#, "youtube"),
        (#"telegram|电报|電報|\btg\b"#, "telegram"),
        (#"google|谷歌"#, "google"),
        (#"github"#, "github"),
        (#"spotify"#, "spotify"),
        (#"tiktok|抖音国际|抖音國際"#, "tiktok"),
        (#"(?<!国际)抖音(?!国际|國際)|douyin"#, "douyin"),
        (#"claude|anthropic"#, "anthropic"),
        (#"disney"#, "disney"),
        (#"巴哈姆特|巴哈|bahamut"#, "bahamut"),
        (#"facebook|脸书|臉書|\bfb\b|\bmeta\b"#, "facebook"),
        (#"instagram|\bins\b|\big\b"#, "instagram"),
        (#"microsoft|微软|微軟|onedrive|outlook|office\s*365"#, "microsoft"),
        (#"apple|苹果|蘋果|icloud|app\s*store"#, "apple"),
        (#"twitter|推特|(?<![a-z0-9.])x(?![a-z0-9.])"#, "twitter"),
        (#"discord"#, "discord"),
        (#"prime\s*video"#, "primevideo"),
        (#"amazon|亚马逊|亞馬遜"#, "amazon"),
        (#"steam"#, "steam"),
        (#"bilibili|b\s*站|哔哩哔哩|嗶哩嗶哩"#, "bilibili"),
        (#"reddit"#, "reddit"),
        (#"twitch"#, "twitch"),
        (#"paypal"#, "paypal"),
        (#"\bbing\b|必应|必應"#, "bing"),
        (#"pixiv"#, "pixiv"),
        (#"\bhbo\b"#, "hbo"),
        (#"perplexity"#, "perplexity"),
        (#"grok|\bxai\b"#, "xai"),
        (#"流媒体|流媒體|串流|视频网站|影音"#, "category-media"),
        (#"游戏|遊戲|\bgames?\b"#, "category-games"),
        (#"(国内|中国|大陆|大陸|中國)\s*(网站|網站|域名|服务|服務)"#, "cn"),
        (#"(国内|中国|大陆|大陸|中國)\s*ip"#, "geoip:cn"),
        (#"局域网|局域網|(?<!国|國)内网|(?<!国|國)內網|私有地址|\blan\b"#, "geoip:private"),
        (#"广告|廣告|\bads?\b"#, "category-ads-all"),
    ]

    /// Catalog reference for a service name from `services`.
    static func catalog(_ name: String) -> RuleSetReference {
        name.hasPrefix("geoip:") ? .catalog(source: "metacubex-geoip", name: String(name.dropFirst(6))) : .catalog(source: "metacubex-geosite", name: name)
    }

    /// RULE-SET rules whose rule-set name is the service ("netflix", "Netflix", "netflix-2") and
    /// GEOSITE rules for it.
    static func serviceRules(_ geosite: String, in rules: [String]) -> [(type: String, payload: String)] {
        func key(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let isGeoIP = geosite.hasPrefix("geoip:")
        let bare = isGeoIP ? String(geosite.dropFirst(6)) : geosite
        // Veer names geoip rule sets "<name>-ip".
        let wanted = key(bare) + (isGeoIP ? "ip" : "")
        var found: [(type: String, payload: String)] = []
        for rule in rules {
            let parts = rule.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let type = parts[0].uppercased(), payload = parts[1]
            let matches = type == "RULE-SET" ? key(payload) == wanted || key(payload).hasPrefix(wanted) && key(payload).dropFirst(wanted.count).allSatisfy(\.isNumber)
                : type == (isGeoIP ? "GEOIP" : "GEOSITE") && payload.lowercased() == bare.lowercased()
            if matches, !found.contains(where: { $0.type == type && $0.payload == payload }) { found.append((type, payload)) }
        }
        return found
    }

    /// IPv4/IPv6 addresses and CIDR networks in a clause, as rules (a bare address becomes /32 or /128).
    static func ipNetworks(in text: String) -> [(type: String, cidr: String)] {
        var found: [(type: String, cidr: String)] = []
        for raw in matchesOf(#"(?<![0-9a-f:.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![0-9.])|(?<![0-9a-z:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:/\d{1,3})?(?![0-9a-z:])"#, in: text) {
            let parts = raw.split(separator: "/")
            guard let address = IPAddress(String(parts[0])) else { continue }
            let v6 = address.bytes.count == 16
            let cidr = parts.count > 1 ? raw : "\(raw)/\(v6 ? 128 : 32)"
            guard IPAddress.network(cidr) != nil, !found.contains(where: { $0.cidr == cidr }) else { continue }
            found.append((v6 ? "IP-CIDR6" : "IP-CIDR", cidr))
        }
        return found
    }

    /// The region or exit a clause names ("日本", "@香港出口"), for a follow-up question.
    static func mentionedPlace(_ clause: String, exits: [Target]) -> String? {
        if let named = exits.map(\.name).sorted(by: { $0.count > $1.count }).first(where: { clause.contains($0) }) { return named }
        return Region.allCases.first { $0.instructionPattern.map(clause.matches) ?? false }?.displayName
    }

    static let outOfScopePattern = #"延迟|太卡|很卡|卡顿|最快|测速|ping|latency|slow|fastest|换个?节点|换一个|切换节点|开启?vpn|启动vpn|关闭vpn|连接代理|断开"#

    public static let outOfScopeMessage = "我只编辑分流规则，不能测速、启动 VPN 或切换运行中的节点。你可以指定一个出口，例如“YouTube 走香港”。"

    /// True when the instruction asks for something outside rule editing. Checked before any AI call.
    public static func isOutOfScope(_ prompt: String) -> Bool { prompt.matches(outOfScopePattern) }

    /// `rules` are the draft's current rules; deleting a service ("删除 Netflix 规则") removes the
    /// rule-set and GEOSITE rules that actually exist for it.
    public static func parse(_ prompt: String, targets: [Target], regions: [String: Region], rules: [String] = []) throws -> AssistantReply {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorError("请输入希望修改的分流，例如“Netflix 走日本”。") }
        if isOutOfScope(trimmed) { return .outOfScope(outOfScopeMessage) }

        let exits = targets.filter { $0.kind != .builtin }
        let suggestions = Array(exits.filter { $0.kind == .group }.prefix(4).map(\.name))
        let exitNames = exits.map(\.name)
        var operations: [EditPlan.Operation] = []
        var newGroupCount = 0
        let allClauses = mergeExitOnlyClauses(clauses(trimmed, exitNames: exits.map(\.name)), exitNames: exits.map(\.name))
        let clauseCount = allClauses.count
        for clause in allClauses {
            // Deleting comes first: "去掉 example.com 的规则" is a removal, not a negation.
            let removing = clause.matches(#"删除|移除|删掉|刪除|remove|delete"#) || clause.matches(#"(去掉|取消|不要).{0,40}规则"#)
            // Exclusions with a region ("排除港澳") are handled by resolveExit; other negations are not.
            let negated = !removing && clause.matches(#"不要|不走|别走|别用|不使用|除了|除外|排除|去掉|except|unless|\bnot\b|don't"#)
            if negated && !Region.allCases.contains(where: { $0.instructionPattern.map(clause.matches) ?? false }) {
                throw EditorError("本地解析不支持这种否定或例外条件。可以说“排除港澳”这样的地区排除，或切换到 AI 解析。")
            }
            // Strip exit names before looking for domains so names like "hk.example" don't count.
            var scan = clause
            for name in exits.map(\.name).sorted(by: { $0.count > $1.count }) { scan = scan.replacingOccurrences(of: name, with: " ") }
            let domains = matchesOf(#"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b"#, in: scan).map { $0.lowercased() }
            // IP addresses and networks: 10.0.0.0/8, 192.168.1.1, 2001:db8::/32.
            let networks = ipNetworks(in: scan)
            let geosites = domains.isEmpty && networks.isEmpty ? services.filter { scan.matches($0.pattern) }.map(\.geosite) : []
            guard !domains.isEmpty || !geosites.isEmpty || !networks.isEmpty else {
                if clauseCount == 1, let place = mentionedPlace(clause, exits: exits) {
                    // Only where to send it, not what: ask instead of failing.
                    return .clarification("哪些流量走\(place)？可以说服务、域名或 IP，例如：", options: ["Netflix", "YouTube", "ChatGPT"].map {
                        ClarifyOption(label: $0, prompt: "\($0) 走\(place)")
                    })
                }
                throw EditorError("本地解析认识常见服务（如 Netflix、YouTube、ChatGPT、Claude、Google、Apple、微软、B站、Steam、广告、国内网站、局域网）、明确的域名和 IP。其他说法请切换到 AI 解析。")
            }

            if removing {
                for domain in domains { operations.append(.removeRule(matchType: "DOMAIN-SUFFIX", match: domain)) }
                for network in networks { operations.append(.removeRule(matchType: network.type, match: network.cidr)) }
                for geosite in geosites {
                    let found = serviceRules(geosite, in: rules)
                    guard !found.isEmpty else {
                        throw EditorError("配置中没有\(RuleSetCatalog.displayName(for: geosite))相关的规则集或 GEOSITE 规则，无需删除。")
                    }
                    operations += found.map { .removeRule(matchType: $0.type, match: $0.payload) }
                }
                continue
            }

            let targetID: String
            switch try resolveExit(clause, targets: targets, regions: regions, defaultReject: geosites == ["category-ads-all"]) {
            case .target(let found): targetID = found.id
            case let .newGroup(groupRegions, members, excluded):
                // One service, several regions or exits: a group named after the service holds them all.
                newGroupCount += 1
                let id = "new-\(newGroupCount)"
                let subjects = geosites.map(RuleSetCatalog.displayName(for:)) + domains
                let name = subjects.isEmpty ? "新策略组" : String(subjects.prefix(3).joined(separator: "、").prefix(60))
                operations.append(.group(EditPlan.NewGroup(id: id, name: name, regions: groupRegions, members: members.map(\.id), excludeRegions: excluded)))
                targetID = id
            case .ask(let question, let names):
                // Each choice rewrites only this clause's exit phrase, so answering never repeats the question.
                let choices = names.isEmpty ? suggestions : names
                return .clarification(question, options: choices.map {
                    ClarifyOption(label: $0, prompt: resolved(trimmed, clause: clause, exit: $0, exitNames: exitNames))
                })
            }
            for domain in domains { operations.append(.route(matchType: "DOMAIN-SUFFIX", match: domain, targetId: targetID)) }
            for network in networks {
                operations.append(.route(matchType: network.type, match: network.cidr, targetId: targetID))
            }
            for geosite in geosites {
                operations.append(.ruleSet(catalog(geosite), targetId: targetID))
            }
        }
        guard !operations.isEmpty else { throw EditorError("没有识别到可执行的修改。") }
        guard operations.count <= 32 else { throw EditorError("一次最多 32 项修改，请拆分指令。") }
        return .plan(EditPlan(operations: operations))
    }

    enum ExitResolution {
        case target(Target)
        case ask(String, [String])
        /// Several regions and/or named exits for one clause, or "every region except these".
        case newGroup(regions: [Region], members: [Target], excluded: [Region])
    }

    static func resolveExit(_ clause: String, targets: [Target], regions: [String: Region], defaultReject: Bool) throws -> ExitResolution {
        let exits = targets.filter { $0.kind != .builtin }
        let direct = clause.matches(#"直连|\bdirect\b|不走代理|不代理"#)
        let reject = clause.matches(#"屏蔽|拦截|拒绝|阻止|\breject\b|\bblock\b"#)
        let named = exits.filter { clause.contains($0.name) }
        // Look for region words outside exit names, so "[A]JP PrivateNET" or "US-01" don't count as a region request.
        var regionScan = clause
        for name in exits.map(\.name).sorted(by: { $0.count > $1.count }) { regionScan = regionScan.replacingOccurrences(of: name, with: " ") }
        let longestNamed = named.filter { candidate in !named.contains { $0.name != candidate.name && $0.name.contains(candidate.name) } }
        // In the order the user wrote them ("台湾和香港" → TW, HK).
        let asked = Region.allCases
            .compactMap { region -> (Region, String.Index)? in
                guard let pattern = region.instructionPattern,
                      let range = regionScan.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
                return (region, range.lowerBound)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        let actions = (direct ? 1 : 0) + (reject ? 1 : 0) + (longestNamed.isEmpty && asked.isEmpty ? 0 : 1)
        if actions > 1 {
            throw EditorError("同一句里既有代理出口又有直连或拦截，请拆成两句。")
        }
        if clause.matches(#"排除|除了|除去|去掉|不要|不走|不含|别走|except"#), !asked.isEmpty, longestNamed.isEmpty, !direct, !reject {
            return .newGroup(regions: [], members: [], excluded: asked)
        }
        if longestNamed.count + asked.count > 1 {
            return .newGroup(regions: asked, members: longestNamed, excluded: [])
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

    /// `prompt` with this clause's region word (or "走代理") replaced by `@exit`.
    static func resolved(_ prompt: String, clause: String, exit: String, exitNames: [String]) -> String {
        var fixed = clause
        let patterns = Region.allCases.compactMap(\.instructionPattern) + [#"走\s*代理|走\s*proxy"#]
        let ranges = patterns.compactMap { clause.range(of: $0, options: [.regularExpression, .caseInsensitive]) }
        if let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) {
            let replaced = String(clause[first])
            fixed.replaceSubrange(first, with: replaced.hasPrefix("走") ? "走 @\(exit)" : "@\(exit)")
        } else {
            fixed = clause + " 走 @\(exit)"
        }
        guard let range = prompt.range(of: clause) else { return fixed }
        return prompt.replacingCharacters(in: range, with: fixed)
    }

    /// "所有国外 AI 服务，策略组排除港澳" splits into a subject-only and an exit-only clause; join a
    /// clause that names no service or domain onto the previous one.
    static func mergeExitOnlyClauses(_ clauses: [String], exitNames: [String]) -> [String] {
        var merged: [String] = []
        for clause in clauses {
            var scan = clause
            for name in exitNames.sorted(by: { $0.count > $1.count }) { scan = scan.replacingOccurrences(of: name, with: " ") }
            let hasSubject = !matchesOf(#"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\b"#, in: scan).isEmpty
                || services.contains { scan.matches($0.pattern) }
            if !hasSubject, let last = merged.popLast() { merged.append(last + " " + clause) } else { merged.append(clause) }
        }
        return merged
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
        // "、" lists items inside one clause ("台湾、香港"), so it is not a separator.
        let parts = protected.components(separatedBy: CharacterSet(charactersIn: "\n;；,，。"))
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
