import Foundation
import Testing
@testable import VeerCore

enum Links {
    // Placeholder credentials and .invalid hosts only.
    static let ss = "ss://\(Data("aes-128-gcm:pass-1".utf8).base64EncodedString())@ss.example.invalid:8388#🇯🇵 东京 SS"
    static let ssPlain = "ss://2022-blake3-aes-128-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng%3D%3D@ss2.example.invalid:443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.invalid#HK%20Obfs"
    static let ssLegacy = "ss://\(Data("chacha20-ietf-poly1305:pw@legacy.example.invalid:8000".utf8).base64EncodedString())#Legacy"
    static let vmessJSON = #"{"v":"2","ps":"🇺🇸 美国 WS","add":"vm.example.invalid","port":"443","id":"11111111-1111-1111-1111-111111111111","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.example.invalid","path":"/ray?ed=2048","tls":"tls","sni":"cdn.example.invalid"}"#
    static let vmess = "vmess://" + Data(vmessJSON.utf8).base64EncodedString()
    static let vless = "vless://22222222-2222-2222-2222-222222222222@vl.example.invalid:443?encryption=none&security=reality&sni=www.example.invalid&fp=safari&pbk=3HpIFZezAxkt9pjjpr6xtLcBk7q1WoYs-k5c5Ui5GS0&sid=ab12&type=grpc&serviceName=svc&flow=xtls-rprx-vision#SG%20Reality"
    static let trojan = "trojan://trojan-pass@tj.example.invalid:443?sni=tj.example.invalid&type=ws&path=%2Fws&host=tj.example.invalid&allowInsecure=1#Trojan 台湾"
    static let hy2 = "hysteria2://hy-auth@hy.example.invalid:443,20000-30000/?sni=hy.example.invalid&obfs=salamander&obfs-password=ob&insecure=1#Hy2 日本"
    static let tuic = "tuic://33333333-3333-3333-3333-333333333333:tuic-pass@tu.example.invalid:443?congestion_control=bbr&alpn=h3&sni=tu.example.invalid&udp_relay_mode=native#TUIC"
    static let socks = "socks5://user:pw@127.0.0.1:1080#Local SOCKS"
    static let unsupported = "wireguard://key@wg.example.invalid:51820#WG"
    static var all: String { [ss, ssPlain, ssLegacy, vmess, vless, trojan, hy2, tuic, socks, unsupported].joined(separator: "\n") }
}

struct ImportDetectionTests {
    @Test func mihomoYAMLIsKeptVerbatim() throws {
        let result = try ConfigImporter.normalize(SampleConfig.text)
        #expect(result.format == .mihomoYAML && result.text == SampleConfig.text && result.note == nil)
    }

    @Test func base64SubscriptionsAreDecodedInEveryCommonShape() throws {
        let raw = Data(Links.all.utf8).base64EncodedString()
        let wrapped = stride(from: 0, to: raw.count, by: 76).map { i in
            String(raw[raw.index(raw.startIndex, offsetBy: i)..<raw.index(raw.startIndex, offsetBy: min(i + 76, raw.count))])
        }.joined(separator: "\r\n")
        let urlSafe = raw.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for input in [raw, wrapped, urlSafe, "\u{FEFF}" + raw + "\n"] {
            let result = try ConfigImporter.normalize(input)
            #expect(result.format == .base64Links)
            #expect(result.nodeCount == 9)
            #expect(result.skipped == ["wireguard": 1])
        }
    }

    @Test func plainLinkListsBuildAUsableConfig() throws {
        let result = try ConfigImporter.normalize(Links.all)
        #expect(result.format == .plainLinks)
        let doc = try ConfigDocument.parse(result.text)
        #expect(doc.counts.nodes == 9)
        let groups = doc.targets.filter { $0.kind == .group }.map(\.name)
        #expect(groups.prefix(2) == ["节点选择", "自动选择"])
        #expect(Set(groups).isSuperset(of: ["日本节点", "美国节点", "台湾节点"]))
        #expect(doc.rules == ["MATCH,节点选择"])
        #expect(doc.warnings.isEmpty)
        #expect(result.text.contains(#"- name: "🇯🇵 东京 SS""#) && !result.text.contains("\\U0001F1"))
        #expect(result.note?.contains("wireguard 1 个") == true)
        // The editor can route to the generated groups right away.
        let plan = EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "youtube"), targetId: doc.target(named: "日本节点")!.id)])
        #expect(try ConfigDocument.parse(PlanApplier.apply(plan, to: doc).candidate).rules.first == "RULE-SET,youtube,日本节点")
    }

    @Test func yamlNodeListsAreWrapped() throws {
        let list = """
        - {name: "JP 01", type: ss, server: a.example.invalid, port: 443, cipher: aes-128-gcm, password: "123456"}
        - {name: "JP 01", type: trojan, server: b.example.invalid, port: 443, password: x, udp: yes}
        """
        let result = try ConfigImporter.normalize(list)
        #expect(result.format == .proxyListYAML && result.nodeCount == 2)
        let doc = try ConfigDocument.parse(result.text)
        #expect(doc.targets.filter { $0.kind == .node }.map(\.name) == ["JP 01", "JP 01-01"])
        #expect(result.text.contains("password: '123456'"))
        #expect(result.text.contains("udp: 'yes'"))
        let provider = try ConfigImporter.normalize("proxies:\n" + list.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n"))
        #expect(provider.format == .proxyListYAML)
    }

    @Test(arguments: [
        ("<!DOCTYPE html><html><body>login</body></html>", "网页"),
        (#"{"inbounds":[],"outbounds":[{"type":"direct"}],"route":{}}"#, "sing-box"),
        ("   \n", "空的"),
        ("hello world", "无法识别"),
        (Links.unsupported, "wireguard"),
    ])
    func explainsWhatItCannotImport(input: String, expected: String) {
        #expect { try ConfigImporter.normalize(input) } throws: { ($0 as? EditorError)?.message.contains(expected) == true }
    }
}

struct ShareLinkTests {
    func proxy(_ link: String) throws -> YAMLValue {
        let result = ShareLinkParser.parse(link)
        return .map(try #require(result.proxies.first))
    }

    @Test func shadowsocksForms() throws {
        let sip = try proxy(Links.ss)
        #expect(sip["cipher"] == .string("aes-128-gcm") && sip["password"] == .string("pass-1") && sip["port"] == .int(8388))
        #expect(sip["name"] == .string("🇯🇵 东京 SS"))
        let plain = try proxy(Links.ssPlain)
        #expect(plain["cipher"] == .string("2022-blake3-aes-128-gcm") && plain["password"] == .string("MTIzNDU2Nzg5MDEyMzQ1Ng=="))
        #expect(plain["plugin"] == .string("obfs") && plain["plugin-opts"]?["host"] == .string("cdn.example.invalid"))
        let legacy = try proxy(Links.ssLegacy)
        #expect(legacy["server"] == .string("legacy.example.invalid") && legacy["password"] == .string("pw"))
    }

    @Test func vmessJSONWithEarlyData() throws {
        let vmess = try proxy(Links.vmess)
        #expect(vmess["tls"] == .bool(true) && vmess["servername"] == .string("cdn.example.invalid") && vmess["network"] == .string("ws"))
        #expect(vmess["ws-opts"]?["path"] == .string("/ray"))
        #expect(vmess["ws-opts"]?["max-early-data"] == .int(2048))
        #expect(vmess["ws-opts"]?["headers"]?["Host"] == .string("cdn.example.invalid"))
    }

    @Test func vlessRealityGrpc() throws {
        let vless = try proxy(Links.vless)
        #expect(vless["reality-opts"] == .map([("public-key", .string("3HpIFZezAxkt9pjjpr6xtLcBk7q1WoYs-k5c5Ui5GS0")), ("short-id", .string("ab12"))]))
        #expect(vless["client-fingerprint"] == .string("safari") && vless["flow"] == .string("xtls-rprx-vision"))
        #expect(vless["grpc-opts"]?["grpc-service-name"] == .string("svc"))
    }

    @Test func trojanHysteria2TuicSocks() throws {
        let trojan = try proxy(Links.trojan)
        #expect(trojan["skip-cert-verify"] == .bool(true) && trojan["ws-opts"]?["path"] == .string("/ws"))
        let hy2 = try proxy(Links.hy2)
        #expect(hy2["port"] == .int(443) && hy2["ports"] == .string("443,20000-30000") && hy2["obfs"] == .string("salamander"))
        let tuic = try proxy(Links.tuic)
        #expect(tuic["uuid"] == .string("33333333-3333-3333-3333-333333333333") && tuic["alpn"] == .list([.string("h3")]))
        let socks = try proxy(Links.socks)
        #expect(socks["type"] == .string("socks5") && socks["username"] == .string("user"))
    }
}
