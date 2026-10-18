import Foundation
import Testing
@testable import VeerCore

struct NodeCleanupTests {
    // Placeholder credentials and .invalid hosts only.
    static func trojan(_ name: String, host: String = "jp.example.invalid", password: String = "pw") -> String {
        "trojan://\(password)@\(host):443?sni=\(host)#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!)"
    }

    static let subscription = [
        trojan("剩余流量：123.45 GB", host: "info1.example.invalid"),
        trojan("套餐到期：2026-12-31", host: "info2.example.invalid"),
        trojan("官网 www.example.invalid", host: "info3.example.invalid"),
        trojan("Expire: 2026/12/31", host: "info4.example.invalid"),
        trojan("JP 01"),
        trojan("JP 01 备用"),                                   // same settings as JP 01
        trojan("JP 02", password: "other"),                    // same server, other credentials
        trojan("🇺🇸 美国 01", host: "us.example.invalid"),
        trojan("香港 0.5x 倍率", host: "hk.example.invalid"),   // a rate is not a notice
        trojan("Node 1Gbps", host: "fast.example.invalid"),
    ].joined(separator: "\n")

    func names(_ result: ConfigImporter.Result) throws -> [String] {
        try ConfigDocument.parse(result.text).targets.filter { $0.kind == .node }.map(\.name)
    }

    @Test func removesInformationNodesAndReportsThem() throws {
        let result = try ConfigImporter.normalize(Self.subscription, options: .init(removeDuplicates: false))
        #expect(result.cleanup.infoNodes == ["剩余流量：123.45 GB", "套餐到期：2026-12-31", "官网 www.example.invalid", "Expire: 2026/12/31"])
        #expect(try names(result) == ["JP 01", "JP 01 备用", "JP 02", "🇺🇸 美国 01", "香港 0.5x 倍率", "Node 1Gbps"])
        #expect(result.nodeCount == 6)
        #expect(result.note?.contains("已移除 4 个信息节点（“剩余流量：123.45 GB”、“套餐到期：2026-12-31”、“官网 www.example.invalid” 等）") == true)
        // Groups never list the notices.
        #expect(!result.text.contains("剩余流量"))
    }

    @Test func removesExactDuplicatesKeepingTheFirst() throws {
        let result = try ConfigImporter.normalize(Self.subscription, options: .init(removeInfoNodes: false))
        #expect(result.cleanup.duplicates == ["JP 01 备用"])
        let kept = try names(result)
        #expect(kept.contains("JP 01") && !kept.contains("JP 01 备用") && kept.contains("JP 02"))
        #expect(result.note?.contains("已移除 1 个重复节点") == true)

        // YAML lists: scalar types and server case do not hide a duplicate; any other field does.
        let list = """
        - {name: A, type: ss, server: Dup.Example.Invalid, port: 443, cipher: aes-128-gcm, password: p}
        - {name: B, type: ss, server: dup.example.invalid, port: "443", cipher: aes-128-gcm, password: p}
        - {name: C, type: ss, server: dup.example.invalid, port: 443, cipher: aes-128-gcm, password: p, udp: true}
        """
        let yaml = try ConfigImporter.normalize(list)
        #expect(yaml.cleanup.duplicates == ["B"])
        #expect(try names(yaml) == ["A", "C"])
    }

    @Test func defaultsCombineBothAndSummarizeInOneSentence() throws {
        let result = try ConfigImporter.normalize(Data(Self.subscription.utf8).base64EncodedString())
        #expect(result.format == .base64Links && result.nodeCount == 5)
        #expect(result.cleanup == CleanupReport(infoNodes: result.cleanup.infoNodes, duplicates: ["JP 01 备用"]))
        #expect(result.note?.contains("个信息节点（") == true && result.note?.contains("等）、1 个重复节点。") == true)
        let off = try ConfigImporter.normalize(Self.subscription, options: .init(removeInfoNodes: false, removeDuplicates: false))
        #expect(off.nodeCount == 10 && off.cleanup.isEmpty && off.note?.contains("已移除") == false)
    }

    @Test func addsRegionFlagsOnlyWhenAsked() throws {
        let plain = try ConfigImporter.normalize(Self.subscription)
        #expect(try names(plain).first == "JP 01")
        let flagged = try ConfigImporter.normalize(Self.subscription, options: .init(addRegionFlags: true))
        // JP gets a flag, the US node already has one, the rate-only and unknown nodes stay as they are.
        #expect(try names(flagged) == ["🇯🇵 JP 01", "🇯🇵 JP 02", "🇺🇸 美国 01", "🇭🇰 香港 0.5x 倍率", "Node 1Gbps"])
        #expect(flagged.cleanup.flagged == 3 && flagged.note?.contains("为 3 个节点添加了地区旗帜") == true)
        let doc = try ConfigDocument.parse(flagged.text)
        #expect(doc.target(named: "日本节点") != nil && doc.target(named: "香港节点") != nil)
        #expect(NodeCleanup.flag(for: .gb) == "🇬🇧" && NodeCleanup.flag(for: .unknown) == nil)
    }

    @Test func subscriptionsWithOnlyNoticesExplainWhy() throws {
        let expired = [Self.trojan("剩余流量：0 GB", host: "a.example.invalid"), Self.trojan("套餐已过期", host: "b.example.invalid")].joined(separator: "\n")
        #expect { try ConfigImporter.normalize(expired) } throws: { ($0 as? EditorError)?.message.contains("已过期") == true }
        #expect(try ConfigImporter.normalize(expired, options: .init(removeInfoNodes: false)).nodeCount == 2)
    }

    /// The editor only edits rules of a user's own Mihomo config; its proxies are never cleaned.
    @Test func fullMihomoConfigsAreUntouched() throws {
        let yaml = """
        mixed-port: 7890
        proxies:
          - {name: "剩余流量：10 GB", type: ss, server: a.example.invalid, port: 443, cipher: aes-128-gcm, password: p}
          - {name: "JP 01", type: ss, server: b.example.invalid, port: 443, cipher: aes-128-gcm, password: p}
          - {name: "JP 01 copy", type: ss, server: b.example.invalid, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: ["剩余流量：10 GB", "JP 01", "JP 01 copy"]}
        rules:
          - MATCH,PROXY

        """
        let result = try ConfigImporter.normalize(yaml, options: .init(removeInfoNodes: true, removeDuplicates: true, addRegionFlags: true))
        #expect(result.format == .mihomoYAML && result.text == yaml && result.cleanup.isEmpty && result.note == nil)
    }
}
