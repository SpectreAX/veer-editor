import Foundation
import Testing
@testable import VeerCore

/// Merging subscriptions, keep / exclude filters and rename rules. Placeholder hosts only.
struct MergeFilterTests {
    static let trojan = NodeCleanupTests.trojan

    static let airportA = [
        trojan("香港 01", "hk1.a.example.invalid", "a"),
        trojan("日本 01", "jp1.a.example.invalid", "a"),
        trojan("美国 01 0.1x 过期", "us1.a.example.invalid", "a"),
    ].joined(separator: "\n")

    static let airportB = """
    proxies:
      - {name: 香港 01, type: ss, server: hk.b.example.invalid, port: 443, cipher: aes-128-gcm, password: b}
      - {name: 新加坡 01, type: ss, server: sg.b.example.invalid, port: 443, cipher: aes-128-gcm, password: b}
    proxy-groups:
      - {name: Proxy, type: select, proxies: [香港 01, 新加坡 01]}
    rules:
      - MATCH,Proxy
    """

    func names(_ result: ConfigImporter.Result) throws -> [String] {
        try ConfigDocument.parse(result.text).targets.filter { $0.kind == .node }.map(\.name)
    }

    @Test func mergesSubscriptionsAndPrefixesSharedNames() throws {
        let result = try ConfigImporter.merge([
            .init(label: "机场A", text: Data(Self.airportA.utf8).base64EncodedString()),
            .init(label: "机场B", text: Self.airportB),
        ])
        #expect(result.format == .merged)
        // "美国 01 0.1x 过期" is an expiry notice and goes; only the shared "香港 01" is prefixed.
        #expect(try names(result) == ["机场A 香港 01", "日本 01", "机场B 香港 01", "新加坡 01"])
        #expect(result.sources == [.init(label: "机场A", nodes: 3), .init(label: "机场B", nodes: 2)])
        #expect(result.prefixed == 2)
        let note = try #require(result.note)
        #expect(note.contains("合并了 2 个订阅：机场A（3 个）、机场B（2 个），清理后共 4 个节点"))
        #expect(note.contains("有 2 个节点与其他订阅重名"))
        // Only the nodes of a full config are taken; its groups and rules are not.
        #expect(!result.text.contains("MATCH,Proxy"))
        #expect(result.text.contains("MATCH,节点选择"))
    }

    @Test func mergeNamesTheSubscriptionThatFailed() {
        #expect(throws: EditorError("“机场B”：内容是空的。请导入 Mihomo YAML 配置、Base64 订阅或分享链接列表。")) {
            try ConfigImporter.merge([.init(label: "机场A", text: Self.airportA), .init(label: "机场B", text: "  ")])
        }
        #expect(throws: EditorError("“空配置”里没有节点。")) {
            try ConfigImporter.merge([.init(label: "机场A", text: Self.airportA), .init(label: "空配置", text: "rules:\n  - MATCH,DIRECT\n")])
        }
    }

    @Test func keepsAndExcludesByPattern() throws {
        let links = Self.airportA + "\n" + Self.trojan("香港 02 IPLC", "hk2.a.example.invalid", "a")
        let kept = try ConfigImporter.normalize(links, options: .init(include: "香港|日本", exclude: "iplc"))
        #expect(try names(kept) == ["香港 01", "日本 01"])
        #expect(kept.cleanup.filtered == 1)
        #expect(kept.note?.contains("按筛选条件去掉了 1 个节点") == true)

        #expect(throws: EditorError("按“保留 / 排除”筛选后没有剩下节点。请放宽筛选条件。")) {
            try ConfigImporter.normalize(links, options: .init(include: "德国"))
        }
    }

    @Test func renamesInOrderWithGroups() throws {
        let options = ImportOptions(renames: [.init(find: #"^(香港|日本) (\d+)$"#, replace: "$1-$2"), .init(find: "香港", replace: "HK")])
        let result = try ConfigImporter.normalize(Self.airportA, options: options)
        #expect(try names(result) == ["HK-01", "日本-01"])
        #expect(result.cleanup.renamed == 2)
        // A rule that would empty a name leaves it alone.
        let emptied = try ConfigImporter.normalize(Self.airportA, options: .init(renames: [.init(find: ".*", replace: "")]))
        #expect(try names(emptied) == ["香港 01", "日本 01"])
        #expect(emptied.cleanup.renamed == 0)
    }

    @Test func reportsInvalidPatternsInPlainWords() {
        #expect(ImportOptions(include: "香港(").problem == "“保留”不是有效的正则表达式")
        #expect(ImportOptions(exclude: "[").problem == "“排除”不是有效的正则表达式")
        #expect(ImportOptions(renames: [.init(find: "ok", replace: ""), .init(find: "(", replace: "")]).problem == "第 2 条重命名的“查找”不是有效的正则表达式")
        #expect(ImportOptions(include: "  ", renames: [.init(find: "", replace: "x")]).problem == nil)
    }
}
