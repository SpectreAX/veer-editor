import Foundation
import Testing
@testable import VeerCore

struct ExecutionModeTests {
    static func item(_ kind: ChangeItem.Kind, url: String? = nil) -> ChangeItem {
        ChangeItem(id: 0, kind: kind, subject: "x", matchType: "", match: "", targetName: nil, targetID: nil, replaced: [], rule: nil,
                   provider: url.map { .init(key: "k", url: $0, behavior: "domain", format: "mrs", sourceLabel: "", reused: false, verification: .verified) },
                   group: nil)
    }

    @Test func modesDecideWhatIsWritten() {
        let passed = ValidationResult(status: .passed, message: ""), unavailable = ValidationResult(status: .unavailable, message: ""),
            failed = ValidationResult(status: .failed, message: "")
        let netflix = Self.item(.ruleSet, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/netflix.mrs")
        let broad = Self.item(.ruleSet, url: "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/geolocation-!cn.mrs")
        #expect(!ExecutionMode.manual.writesAutomatically(items: [netflix], validation: passed))
        #expect(!ExecutionMode.plan.writesAutomatically(items: [netflix], validation: passed))
        #expect(ExecutionMode.auto.writesAutomatically(items: [netflix, Self.item(.route)], validation: passed))
        #expect(!ExecutionMode.auto.writesAutomatically(items: [broad], validation: passed))
        #expect(!ExecutionMode.auto.writesAutomatically(items: [Self.item(.removeRule)], validation: passed))
        #expect(!ExecutionMode.auto.writesAutomatically(items: [Self.item(.group)], validation: passed))
        #expect(!ExecutionMode.auto.writesAutomatically(items: [netflix], validation: unavailable))
        #expect(ExecutionMode.acceptEdits.writesAutomatically(items: [Self.item(.removeRule)], validation: passed))
        #expect(!ExecutionMode.acceptEdits.writesAutomatically(items: [netflix], validation: unavailable))
        #expect(ExecutionMode.full.writesAutomatically(items: [Self.item(.group)], validation: unavailable))
        #expect(!ExecutionMode.full.writesAutomatically(items: [netflix], validation: failed))
    }

    @Test func promptsFollowTheMode() {
        #expect(SystemPrompt.build(config: "", mode: .plan).contains("# 当前模式：计划"))
        #expect(SystemPrompt.build(config: "", mode: .full).contains("# 当前模式：完整权限"))
        #expect(!SystemPrompt.build(config: "").contains("# 当前模式"))
        #expect(SystemPrompt.build(config: "").contains("Steam 下载 CDN"))
    }

    @Test func clarificationsCarryOptionsWithRealNames() throws {
        let reply = try EditPlan.decodeReply(#"{"clarification":"选哪种？","options":[{"label":"下载 CDN 直连","prompt":"Steam 下载 CDN 直连，其余 Steam 走策略组2（美国）"},{"label":"建策略组","prompt":"为 Steam 下载 CDN 新建策略组，包含 DIRECT 和策略组2"}]}"#)
        guard case let .clarification(_, options) = reply else { Issue.record("expected clarification"); return }
        #expect(options.count == 2 && options[0].prompt?.contains("策略组2（美国）") == true)
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"clarification":"?","options":[{"label":"a"}]}"#) }
        #expect(throws: EditorError.self) { try EditPlan.decodeReply(#"{"clarification":"?","options":[]}"#) }

        let doc = try ConfigDocument.parse(SampleConfig.text)
        let context = AnonymousContext(targets: doc.targets, regions: Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets))
        let label = try #require(context.label(forName: "美国出口"))
        let bare = String(label.prefix { $0 != "（" })
        #expect(context.restore("其余 Steam 走\(label)") == "其余 Steam 走美国出口")
        #expect(context.restore("包含 DIRECT 和\(bare)") == "包含 DIRECT 和美国出口")
    }

    final class Scripted: AITransport, @unchecked Sendable {
        let replies: [String]
        private let lock = NSLock()
        private(set) var count = 0
        init(_ replies: [String]) { self.replies = replies }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let index = lock.withLock { count += 1; return count - 1 }
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": replies[min(index, replies.count - 1)]]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func planModeRefusesPlansAndRestoresNames() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        let label = try #require(AnonymousContext(targets: doc.targets, regions: regions).label(forName: "美国出口"))
        let direct = doc.target(named: "DIRECT")!.id
        let transport = Scripted([
            #"{"schemaVersion":1,"operations":[{"kind":"route","matchType":"DOMAIN-SUFFIX","match":"steamcontent.com","targetId":"\#(direct)"}]}"#,
            #"{"understanding":"其余走\#(label)","clarification":"Steam 下载 CDN 怎么处理？","options":[{"label":"直连","prompt":"Steam 下载 CDN 直连，其余 Steam 走\#(label)"}]}"#,
        ])
        var request = EditorEngine.Request(prompt: "Steam 下载 CDN 走直连，其他走代理", draft: doc, regions: regions, useAI: true, settings: AISettings(), apiKey: "k")
        request.mode = .plan
        final class Seen: @unchecked Sendable { var understanding = "" }
        let seen = Seen()
        let output = try await EditorEngine(ai: AIClient(transport: transport)).run(request) { event in
            if case .understanding(let text) = event { seen.understanding = text }
        }
        guard case let .clarification(_, options) = output else { Issue.record("expected clarification"); return }
        #expect(transport.count == 2)
        #expect(options.first?.prompt == "Steam 下载 CDN 直连，其余 Steam 走美国出口")
        #expect(seen.understanding == "其余走美国出口")
    }
}
