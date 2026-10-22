import Foundation
import Testing
@testable import VeerCore

struct InstructionLookupTests {
    /// A geodata folder with jal / google sets, a cn geoip list and one ASN network (1.1.1.0/24).
    static func geodata() throws -> GeoDataStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GeoFixture.geosite([
            ("jal", [(2, "jal.co.jp", []), (2, "jal.com", [])]),
            ("tld-!cn", [(2, "jp", [])]),
            ("cloudflare", [(2, "pages.dev", [])]),
            ("google", [(2, "google.com", []), (2, "google.cn", ["cn"])]),
            ("alphabet", [(2, "google.com", [])]),
        ]).write(to: directory.appendingPathComponent("geosite.dat"))
        try GeoFixture.geoip([("au", [([1, 1, 1, 0], 24)]), ("cloudflare", [([1, 1, 1, 0], 24)])])
            .write(to: directory.appendingPathComponent("geoip.dat"))
        try GeoFixture.asnDatabase(network: [1, 1, 1, 0], prefix: 24, number: 13335, organization: "Cloudflare, Inc.")
            .write(to: directory.appendingPathComponent("GeoLite2-ASN.mmdb"))
        return GeoDataStore(directory: directory)
    }

    @Test func findsOwnSetsAndNetworks() async throws {
        let lookup = InstructionLookup(geo: try Self.geodata(), index: nil)
        let hints = try #require(await lookup.hints(for: "www.jal.co.jp、blog.pages.dev 和 maps.google.com 走 @香港出口，1.1.1.1 和 192.168.1.5 走美国",
                                                   exitNames: ["香港出口"]))
        #expect(hints.ownSets == ["www.jal.co.jp": "jal", "maps.google.com": "google"])
        // pages.dev is in cloudflare's set, but that set is not the site's own.
        let pages = try #require(hints.domains.first { $0.domain == "blog.pages.dev" })
        #expect(pages.ownSet == nil && pages.others == ["cloudflare"])
        #expect(hints.domains.first { $0.domain == "www.jal.co.jp" }?.broad == ["tld-!cn"])
        #expect(hints.domains.first { $0.domain == "maps.google.com" }?.others == ["alphabet"])
        let cloudflare = try #require(hints.addresses.first { $0.address == "1.1.1.1" })
        #expect(cloudflare.asn == 13335 && cloudflare.network == "1.1.1.0/24" && cloudflare.geoip == ["au", "cloudflare"])
        #expect(hints.addresses.first { $0.address == "192.168.1.5" }?.isPrivate == true)
        #expect(hints.message.contains("www.jal.co.jp：自己的规则集 jal；宽泛分类 tld-!cn"))
        #expect(hints.message.contains("1.1.1.1：AS13335 Cloudflare, Inc.，网段 1.1.1.0/24；geoip 规则集 au、cloudflare"))
        #expect(hints.message.contains("192.168.1.5：局域网地址"))
        // Exit names are not taken for domains; nothing to look up gives nil.
        #expect(await lookup.hints(for: "Netflix 走 hk.example 出口", exitNames: ["hk.example 出口"]) == nil)
        // Without geodata there are no hints.
        let empty = GeoDataStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(await InstructionLookup(geo: empty, index: nil).hints(for: "www.jal.co.jp 直连") == nil)
    }

    @Test func localParserRoutesBySitesOwnSet() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let regions = Session(title: "", source: .sample, text: SampleConfig.text).regions(for: doc.targets)
        let direct = doc.target(named: "DIRECT")!.id
        guard case .plan(let plan) = try LocalIntentParser.parse("www.jal.co.jp、jal.com 和 example.org 直连", targets: doc.targets, regions: regions,
                                                                ownSets: ["www.jal.co.jp": "jal", "jal.com": "jal"]) else {
            Issue.record("expected plan"); return
        }
        #expect(plan.operations == [.ruleSet(.catalog(source: "metacubex-geosite", name: "jal"), targetId: direct),
                                    .route(matchType: "DOMAIN-SUFFIX", match: "example.org", targetId: direct)])
        // Country codes inside domains are not regions (this used to fail as "proxy and DIRECT in one sentence").
        guard case .plan(let plain) = try LocalIntentParser.parse("www.jal.co.jp 直连", targets: doc.targets, regions: regions) else {
            Issue.record("expected plan"); return
        }
        #expect(plain.operations == [.route(matchType: "DOMAIN-SUFFIX", match: "www.jal.co.jp", targetId: direct)])
        guard case .plan(let japan) = try LocalIntentParser.parse("example.jp 走日本", targets: doc.targets, regions: regions) else {
            Issue.record("expected plan"); return
        }
        #expect(japan.operations == [.route(matchType: "DOMAIN-SUFFIX", match: "example.jp", targetId: doc.target(named: "日本出口")!.id)])
        // Removing still removes the domain rule itself.
        guard case .plan(let removal) = try LocalIntentParser.parse("删除 www.jal.co.jp 的规则", targets: doc.targets, regions: regions,
                                                                   ownSets: ["www.jal.co.jp": "jal"]) else { Issue.record("expected plan"); return }
        #expect(removal.operations == [.removeRule(matchType: "DOMAIN-SUFFIX", match: "www.jal.co.jp")])
    }

    final class Capture: AITransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var bodies: [String] = []
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self)) }
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": #"{"clarification":"走哪个出口？"}"#]]]])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var hints: [LookupHints] = []
        func add(_ event: EditorEngine.Progress) { if case .lookedUp(let found) = event { lock.withLock { hints.append(found) } } }
    }

    @Test func aiRequestsCarryTheLookups() async throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let capture = Capture(), events = Events()
        let engine = EditorEngine(ai: AIClient(transport: capture), lookup: InstructionLookup(geo: try Self.geodata(), index: nil))
        let request = EditorEngine.Request(prompt: "www.jal.co.jp 走 @日本出口", draft: doc, regions: [:], useAI: true, settings: AISettings(), apiKey: "k")
        _ = try await engine.run(request) { events.add($0) }
        #expect(events.hints.first?.ownSets == ["www.jal.co.jp": "jal"])
        let body = try #require(capture.bodies.first)
        #expect(body.contains("本机查询结果") && body.contains("自己的规则集 jal"))
        // The exit name in the instruction is still anonymized.
        #expect(!body.contains("@日本出口"))
        // The system prompt explains the block.
        #expect(AIClient.systemPrompt(config: "", search: false).contains("# 本机查询结果"))
    }
}
