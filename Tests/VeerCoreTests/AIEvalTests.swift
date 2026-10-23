import Foundation
import Testing
@testable import VeerCore

/// Regression set for the AI path: real instructions against `SampleConfig`, sent to a real model.
/// Costs money, so it only runs with `VEER_AI_EVAL=1`; see docs/AI_EVAL.md.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_AI_EVAL"] == "1"))
struct AIEvalTests {
    // MARK: Expectations

    /// Where traffic should go. A region matches any group or node inferred to be there, or a new
    /// group that contains it.
    enum Exit: Sendable, CustomStringConvertible {
        case region(Region), direct, reject
        /// A new group covering these regions and leaving out `excluding`.
        case newGroup(Set<Region>, excluding: Set<Region> = [])

        var description: String {
            switch self {
            case .region(let region): "\(region.displayName)"
            case .direct: "DIRECT"
            case .reject: "REJECT"
            case let .newGroup(regions, excluded):
                "新策略组(\(regions.map(\.displayName).sorted().joined(separator: "+"))\(excluded.isEmpty ? "" : " 排除 " + excluded.map(\.displayName).sorted().joined(separator: "+")))"
            }
        }
    }

    enum Check: Sendable, CustomStringConvertible {
        /// A service: its rule set (RULE-SET or GEOSITE) or one of its domains.
        case service(sets: [String], domains: [String] = [], to: Exit)
        /// A rule with this match type and value.
        case rule(String, String, to: Exit)
        /// A removal whose value contains this text.
        case removes(String)

        var description: String {
            switch self {
            case let .service(sets, domains, exit): "\((sets + domains).joined(separator: "/")) → \(exit)"
            case let .rule(type, match, exit): "\(type),\(match) → \(exit)"
            case .removes(let match): "删除 \(match)"
            }
        }
    }

    enum Expect: Sendable, CustomStringConvertible {
        case plan([Check]), clarify, outOfScope, noChange
        /// A clarification that offers at least two ready-to-run options.
        case choices
        indirect case either(Expect, Expect)
        /// The model checked domains against the draft before answering.
        indirect case diagnosed(Expect)

        var description: String {
            switch self {
            case .plan(let checks): checks.map(\.description).joined(separator: "；")
            case .clarify: "追问"
            case .choices: "追问并给出 2 个以上方案"
            case .diagnosed(let then): "先检查域名，再\(then)"
            case .outOfScope: "超出范围"
            case .noChange: "无需修改"
            case let .either(first, second): "\(first) 或 \(second)"
            }
        }
    }

    struct Case: Sendable {
        let prompt: String
        let expect: Expect
    }

    /// From the 2026-10-19 test report's 45 phrases (AuditProbeTests.parserMatrix) and later bugs.
    static let cases: [Case] = [
        // Diagnosis (2026-10-23): check the domains, then fix or explain. In SampleConfig GEOSITE,cn
        // already sends Bilibili direct, so explaining is right too.
        .init(prompt: "哔哩哔哩一些 CDN 走了代理是怎么回事？",
              expect: .either(.plan([.service(sets: ["bilibili", "bilibili-cdn"], domains: ["bilivideo.com", "hdslb.com", "akamaized.net"], to: .direct)]), .clarify)),
        // Two reasonable ways and no proxy exit named: offer the choices (2026-10-23).
        .init(prompt: "Steam 下载 CDN 走直连，其他域名如商店、社区走代理", expect: .choices),
        .init(prompt: "为什么 GitHub 的下载走了自动选择？我想让 GitHub 全部走美国",
              expect: .plan([.service(sets: ["github"], domains: ["github.com", "githubusercontent.com"], to: .region(.us))])),
        .init(prompt: "Netflix 走日本", expect: .plan([.service(sets: ["netflix"], domains: ["netflix.com"], to: .region(.jp))])),
        .init(prompt: "让 youtube 走香港", expect: .plan([.service(sets: ["youtube"], domains: ["youtube.com"], to: .region(.hk))])),
        .init(prompt: "github.com 直连", expect: .plan([.service(sets: ["github"], domains: ["github.com"], to: .direct)])),
        .init(prompt: "屏蔽广告", expect: .plan([.service(sets: ["category-ads-all", "category-ads"], to: .reject)])),
        .init(prompt: "去掉 example.com 的规则", expect: .plan([.removes("example.com")])),
        .init(prompt: "Google 不要走香港", expect: .either(.plan([.service(sets: ["google"], domains: ["google.com"], to: .newGroup([], excluding: [.hk]))]), .clarify)),
        .init(prompt: "telegram 走 @香港出口", expect: .plan([.service(sets: ["telegram"], domains: ["telegram.org"], to: .region(.hk))])),
        .init(prompt: "抖音直连", expect: .plan([.service(sets: ["douyin"], domains: ["douyin.com"], to: .direct)])),
        .init(prompt: "B站直连", expect: .plan([.service(sets: ["bilibili"], domains: ["bilibili.com"], to: .direct)])),
        .init(prompt: "苹果服务直连", expect: .plan([.service(sets: ["apple", "apple-cn"], domains: ["apple.com"], to: .direct)])),
        .init(prompt: "微软走美国", expect: .plan([.service(sets: ["microsoft"], domains: ["microsoft.com"], to: .region(.us))])),
        .init(prompt: "ChatGPT 和 Claude 走美国", expect: .plan([.service(sets: ["openai"], domains: ["openai.com", "chatgpt.com"], to: .region(.us)),
                                                                .service(sets: ["anthropic"], domains: ["anthropic.com", "claude.ai"], to: .region(.us))])),
        .init(prompt: "openai.com 走美国", expect: .plan([.service(sets: ["openai"], domains: ["openai.com"], to: .region(.us))])),
        .init(prompt: "10.0.0.0/8 直连", expect: .plan([.rule("IP-CIDR", "10.0.0.0/8", to: .direct)])),
        .init(prompt: "192.168.1.1 直连", expect: .either(.plan([.rule("IP-CIDR", "192.168.1.1/32", to: .direct)]), .noChange)),
        .init(prompt: "Steam 下载直连", expect: .plan([.service(sets: ["steam", "steam@cn"], domains: ["steamcontent.com", "steampowered.com"], to: .direct)])),
        .init(prompt: "国外 AI 服务走美国", expect: .plan([.service(sets: ["category-ai-!cn", "category-ai-chat-!cn"], to: .region(.us))])),
        .init(prompt: "所有流媒体走新加坡", expect: .plan([.service(sets: ["category-media", "category-entertainment", "category-media-!cn"], to: .region(.sg))])),
        .init(prompt: "Disney+ 走香港", expect: .plan([.service(sets: ["disney"], domains: ["disneyplus.com"], to: .region(.hk))])),
        .init(prompt: "Spotify 走美国，Netflix 走日本，YouTube 走香港", expect: .plan([
            .service(sets: ["spotify"], domains: ["spotify.com"], to: .region(.us)),
            .service(sets: ["netflix"], domains: ["netflix.com"], to: .region(.jp)),
            .service(sets: ["youtube"], domains: ["youtube.com"], to: .region(.hk)),
        ])),
        .init(prompt: "TikTok 走日本", expect: .plan([.service(sets: ["tiktok"], domains: ["tiktok.com"], to: .region(.jp))])),
        .init(prompt: "Twitter 走美国", expect: .plan([.service(sets: ["twitter", "x"], domains: ["twitter.com", "x.com"], to: .region(.us))])),
        .init(prompt: "Instagram 和 Facebook 走美国", expect: .plan([.service(sets: ["instagram", "facebook"], domains: ["instagram.com"], to: .region(.us)),
                                                                     .service(sets: ["facebook", "meta"], domains: ["facebook.com"], to: .region(.us))])),
        .init(prompt: "PayPal 走美国", expect: .plan([.service(sets: ["paypal"], domains: ["paypal.com"], to: .region(.us))])),
        .init(prompt: "Discord 走日本", expect: .plan([.service(sets: ["discord"], domains: ["discord.com"], to: .region(.jp))])),
        .init(prompt: "Amazon 走美国", expect: .plan([.service(sets: ["amazon"], domains: ["amazon.com"], to: .region(.us))])),
        .init(prompt: "国内网站直连", expect: .either(.plan([.service(sets: ["cn", "geolocation-cn"], to: .direct)]), .noChange)),
        .init(prompt: "局域网直连", expect: .either(.plan([.service(sets: ["private"], to: .direct)]), .noChange)),
        .init(prompt: "走日本", expect: .clarify),
        .init(prompt: "Netflix", expect: .clarify),
        .init(prompt: "NETFLIX 走 JP", expect: .plan([.service(sets: ["netflix"], domains: ["netflix.com"], to: .region(.jp))])),
        .init(prompt: "Netflix 走東京", expect: .plan([.service(sets: ["netflix"], domains: ["netflix.com"], to: .region(.jp))])),
        .init(prompt: "巴哈走台湾", expect: .either(.clarify, .outOfScope)),
        .init(prompt: "Netflix 走日本或者新加坡", expect: .plan([.service(sets: ["netflix"], domains: ["netflix.com"], to: .newGroup([.jp, .sg]))])),
        .init(prompt: "YouTube 走日本和美国", expect: .plan([.service(sets: ["youtube"], domains: ["youtube.com"], to: .newGroup([.jp, .us]))])),
        .init(prompt: "所有国外AI服务，策略组排除所有港澳节点", expect: .plan([.service(sets: ["category-ai-!cn", "category-ai-chat-!cn"], to: .newGroup([], excluding: [.hk, .mo]))])),
        .init(prompt: "所有 .jp 域名走日本", expect: .plan([.rule("DOMAIN-SUFFIX", "jp", to: .region(.jp))])),
        .init(prompt: "日本航空相关域名走直连", expect: .either(.plan([.service(sets: ["jal", "jal-group"], domains: ["jal.co.jp", "jal.com"], to: .direct)]), .clarify)),
        .init(prompt: "把 google 的规则删掉", expect: .plan([.removes("google")])),
        .init(prompt: "测一下哪个节点最快", expect: .outOfScope),
        .init(prompt: "YouTube 走代理", expect: .clarify),
        // 2026-10-23, modelled on real requests (names are placeholders).
        // Diagnosis without a domain: the model has to check before it answers.
        .init(prompt: "B站视频有时候走了代理，帮我看看",
              expect: .diagnosed(.either(.plan([.service(sets: ["bilibili", "bilibili-cdn"], domains: ["bilivideo.com", "hdslb.com", "akamaized.net"], to: .direct)]), .clarify))),
        // The proxy exit is named, so a plan is fine; offering the switchable-group choice is too.
        .init(prompt: "Steam 下载 CDN 直连，其余 Steam 走美国", expect: .either(.plan([
            .service(sets: ["steam@cn"], domains: ["steamcontent.com", "steamserver.net", "steampipe.akamaized.net", "steamcdn-a.akamaihd.net"], to: .direct),
            .service(sets: ["steam"], domains: ["steampowered.com", "steamcommunity.com"], to: .region(.us)),
        ]), .choices)),
        .init(prompt: "新建一个 AI 服务策略组，不要香港节点，ChatGPT 和 Claude 走它", expect: .plan([
            .service(sets: ["openai"], domains: ["openai.com", "chatgpt.com"], to: .newGroup([], excluding: [.hk])),
            .service(sets: ["anthropic"], domains: ["anthropic.com", "claude.ai"], to: .newGroup([], excluding: [.hk])),
        ])),
        // A top-level domain without the dot, and an exit picked with @.
        .init(prompt: "所有以 jp 结尾的域名都走 @日本出口",
              expect: .either(.plan([.rule("DOMAIN-SUFFIX", "jp", to: .region(.jp))]), .plan([.service(sets: ["tld-jp"], to: .region(.jp))]))),
    ]

    // MARK: Checking

    struct Context {
        let document: ConfigDocument
        let regions: [String: Region]

        func region(of id: String) -> Region? {
            document.target(id: id).flatMap { regions[$0.name] }
        }

        func matches(_ exit: Exit, targetId: String, plan: EditPlan) -> Bool {
            let group = plan.operations.lazy.compactMap { operation -> EditPlan.NewGroup? in
                if case .group(let group) = operation, group.id == targetId { group } else { nil }
            }.first
            switch exit {
            case .direct: return document.target(id: targetId)?.name == "DIRECT"
            case .reject: return ["REJECT", "REJECT-DROP"].contains(document.target(id: targetId)?.name ?? "")
            case .region(let expected):
                if let group { return covered(group) == [expected] || Set(group.regions) == [expected] }
                return region(of: targetId) == expected
            case let .newGroup(regions, excluded):
                guard let group else { return false }
                return regions.isSubset(of: covered(group)) && excluded.isSubset(of: Set(group.excludeRegions))
                    && excluded.isDisjoint(with: Set(group.members.compactMap(region(of:))))
            }
        }

        /// Regions a new group draws on: its declared regions and its members' regions.
        func covered(_ group: EditPlan.NewGroup) -> Set<Region> {
            Set(group.regions).union(group.members.compactMap(region(of:))).subtracting([.unknown])
        }

        func satisfied(_ check: Check, by plan: EditPlan) -> Bool {
            plan.operations.contains { operation in
                switch (check, operation) {
                case let (.service(sets, _, exit), .ruleSet(reference, targetId)):
                    let name: String
                    switch reference {
                    case .catalog(_, let catalogName): name = catalogName
                    case .url(let url, _): name = (URL(string: url)?.deletingPathExtension().lastPathComponent ?? url)
                    }
                    return sets.contains { $0.caseInsensitiveCompare(name) == .orderedSame } && matches(exit, targetId: targetId, plan: plan)
                case let (.service(sets, domains, exit), .route(type, match, targetId)):
                    let value = match.lowercased()
                    let hit = type == "GEOSITE" ? sets.contains(value)
                        : domains.contains { value == $0 || value.hasSuffix("." + $0) || $0.hasSuffix("." + value) }
                    return hit && matches(exit, targetId: targetId, plan: plan)
                case let (.rule(type, match, exit), .route(routeType, routeMatch, targetId)):
                    return routeType == type && routeMatch.lowercased() == match.lowercased() && matches(exit, targetId: targetId, plan: plan)
                case let (.removes(text), .removeRule(_, match)):
                    return match.lowercased().contains(text.lowercased())
                default:
                    return false
                }
            }
        }

        /// nil when the output meets the expectation, otherwise what was missing.
        /// `checked`: the model asked Veer to check domains during the turn.
        func failure(_ expect: Expect, output: EditorEngine.Output, checked: Bool = false) -> String? {
            switch (expect, output) {
            case let (.either(first, second), _):
                guard let one = failure(first, output: output, checked: checked), let two = failure(second, output: output, checked: checked) else { return nil }
                return "\(one)；\(two)"
            case let (.diagnosed(then), _):
                return checked ? failure(then, output: output, checked: checked) : "没有检查域名就回答了"
            case let (.choices, .clarification(_, options)):
                return options.filter { $0.prompt != nil }.count >= 2 ? nil : "只给了 \(options.count) 个方案"
            case let (.plan(checks), .proposal(plan, _, _, _)):
                let missing = checks.filter { !satisfied($0, by: plan) }
                return missing.isEmpty ? nil : "缺少：" + missing.map(\.description).joined(separator: "；")
            case (.clarify, .clarification), (.outOfScope, .outOfScope), (.noChange, .noChange):
                return nil
            default:
                return "期望 \(expect)"
            }
        }

        func describe(_ output: EditorEngine.Output) -> String {
            switch output {
            case let .proposal(plan, _, _, validation):
                return "计划（Mihomo \(validation.status)）：" + plan.operations.map(describe).joined(separator: "；")
            case .noChange(let text): return "无需修改：\(text.prefix(60))"
            case let .clarification(question, options): return "追问：\(question.prefix(60)) [\(options.map(\.label).joined(separator: "|"))]"
            case .outOfScope(let text): return "超出范围：\(text.prefix(60))"
            }
        }

        func describe(_ operation: EditPlan.Operation) -> String {
            func exit(_ id: String) -> String { document.target(id: id)?.name ?? id }
            switch operation {
            case let .route(type, match, target): return "\(type),\(match)→\(exit(target))"
            case let .removeRule(type, match): return "删除 \(type),\(match)"
            case let .ruleSet(reference, target):
                switch reference {
                case let .catalog(source, name): return "规则集 \(source)/\(name)→\(exit(target))"
                case let .url(url, _): return "规则集 \(url)→\(exit(target))"
                }
            case .group(let group):
                return "新策略组 \(group.id) \(group.name) 地区=\(group.regions.map(\.rawValue)) 排除=\(group.excludeRegions.map(\.rawValue)) 成员=\(group.members.map(exit))"
            default:
                return "\(operation)"
            }
        }
    }

    // MARK: Running

    /// Counts requests (the cost driver) and the tokens the API reports, around the real transport.
    final class CountingTransport: AITransport, @unchecked Sendable {
        let base = URLSessionTransport()
        private let lock = NSLock()
        private(set) var requests = 0
        private(set) var tokens = 0

        private func record(_ text: String) {
            // Non-streamed bodies and the final stream chunk carry "usage": {"total_tokens": N}.
            guard let range = text.range(of: #""total_tokens"\s*:\s*\d+"#, options: .regularExpression),
                  let value = Int(text[range].split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) else { return }
            lock.withLock { tokens += value }
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { requests += 1 }
            let (data, response) = try await base.send(request)
            record(String(decoding: data, as: UTF8.self))
            return (data, response)
        }

        func lines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
            lock.withLock { requests += 1 }
            let (response, stream) = try await base.lines(request)
            return (response, AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await line in stream {
                            self.record(line)
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            })
        }
    }

    final class Understanding: @unchecked Sendable {
        var text: String?
        var checked = false
    }

    struct Outcome: Sendable {
        let prompt: String
        let failure: String?
        let got: String
        /// The model's last reading of the instruction, to tell a prompt problem from a decoding one.
        let understanding: String?
        let seconds: Double
        let requests: Int
        let tokens: Int
    }

    @Test func aiPathRegressionSet() async throws {
        let env = ProcessInfo.processInfo.environment
        let provider = env["VEER_AI_PROVIDER"].flatMap(AIProvider.init(rawValue:)) ?? .deepSeek
        let settings = AISettings(provider: provider, baseURL: env["VEER_AI_BASE_URL"], model: env["VEER_AI_MODEL"],
                                  thinkingLevel: env["VEER_AI_THINKING"].flatMap(ThinkingLevel.init(rawValue:)) ?? .off)
        // The key never comes from the repo: the environment, or the key Veer saved on this Mac.
        let key = env["VEER_AI_KEY"] ?? FileKeyStore().read(for: provider.rawValue)
        try #require(key != nil || !provider.needsKey, "No key: set VEER_AI_KEY or save one for \(provider.title) in Veer's settings.")
        let search = env["VEER_AI_EVAL_SEARCH"].flatMap(SearchProvider.init(rawValue:)).map {
            SearchConfig(provider: $0, apiKey: $0.aiServiceKey == provider ? key : nil)
        }
        let geo = env["VEER_AI_EVAL_GEODATA"].map { GeoDataStore(directory: URL(fileURLWithPath: $0)) }
        let filter = env["VEER_AI_EVAL_FILTER"]
        let parallel = max(1, Int(env["VEER_AI_EVAL_PARALLEL"] ?? "") ?? 4)

        let document = try ConfigDocument.parse(SampleConfig.text)
        let context = Context(document: document, regions: Session(title: "", source: .sample, text: SampleConfig.text).regions(for: document.targets))
        // "a|b" runs every case containing a or b.
        let filters = filter?.split(separator: "|").map(String.init)
        let selected = Self.cases.filter { item in filters.map { $0.contains { item.prompt.localizedCaseInsensitiveContains($0) } } ?? true }
        print("AI EVAL \(provider.title) · \(settings.modelLabel) · \(selected.count) 条 · 并发 \(parallel)\(search.map { " · 搜索 \($0.provider.rawValue)" } ?? "")\(geo == nil ? "" : " · 本机地理数据")")

        func run(_ item: Case) async -> Outcome {
            let transport = CountingTransport()
            let engine = EditorEngine(ai: AIClient(transport: transport),
                                      searcher: WebSearchService(geo: geo), lookup: geo.map { InstructionLookup(geo: $0) },
                                      checker: DomainChecker(geo: geo))
            var request = EditorEngine.Request(prompt: item.prompt, draft: document, regions: context.regions, useAI: true,
                                               settings: settings, apiKey: key)
            request.search = search
            let start = Date()
            let failure: String?, got: String
            let understanding = Understanding()
            do {
                let output = try await engine.run(request) { progress in
                    if case .understanding(let text) = progress { understanding.text = text }
                    if case .checking = progress { understanding.checked = true }
                }
                failure = context.failure(item.expect, output: output, checked: understanding.checked)
                got = context.describe(output)
            } catch {
                failure = "出错"
                got = (error as? EditorError)?.message ?? (error as? AIFailure)?.message ?? "\(error)"
            }
            return Outcome(prompt: item.prompt, failure: failure, got: got, understanding: understanding.text, seconds: Date().timeIntervalSince(start),
                           requests: transport.requests, tokens: transport.tokens)
        }

        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            var next = selected.makeIterator()
            for _ in 0..<parallel { if let item = next.next() { group.addTask { await run(item) } } }
            for await outcome in group {
                outcomes.append(outcome)
                print(String(format: "AI EVAL %@ %5.1fs %d 次请求  %@", outcome.failure == nil ? "✓" : "✗", outcome.seconds, outcome.requests, outcome.prompt))
                if let item = next.next() { group.addTask { await run(item) } }
            }
        }

        let order = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ($1.prompt, $0) })
        outcomes.sort { order[$0.prompt, default: 0] < order[$1.prompt, default: 0] }
        let passed = outcomes.filter { $0.failure == nil }.count
        let requests = outcomes.map(\.requests).reduce(0, +), tokens = outcomes.map(\.tokens).reduce(0, +)
        print("\nAI EVAL 结果：\(passed)/\(outcomes.count) 通过（\(outcomes.isEmpty ? 0 : passed * 100 / outcomes.count)%）· 共 \(requests) 次请求\(tokens > 0 ? " · \(tokens) tokens" : "")")
        for outcome in outcomes where outcome.failure != nil {
            let expected = selected.first { $0.prompt == outcome.prompt }?.expect.description ?? ""
            print("\n✗ \(outcome.prompt)\n  期望：\(expected)\n  问题：\(outcome.failure!)\n  得到：\(outcome.got)"
                  + (outcome.understanding.map { "\n  理解：\($0)" } ?? ""))
        }
        if let minimum = env["VEER_AI_EVAL_MIN"].flatMap(Int.init) {
            #expect(passed * 100 >= minimum * max(outcomes.count, 1), "pass rate below \(minimum)%")
        }
    }
}
