import Foundation
import Testing
@testable import VeerCore

struct SubscriptionMetadataTests {
    @Test func namesComeFromProfileTitleThenFilename() {
        #expect(SubscriptionResponse(text: "", headers: ["Content-Disposition": "attachment; filename*=UTF-8''TAG_OpenClash_1016.yaml"]).title == "TAG_OpenClash_1016.yaml")
        #expect(SubscriptionResponse(text: "", headers: ["content-disposition": #"attachment; filename="my sub.yaml""#]).title == "my sub.yaml")
        #expect(SubscriptionResponse(text: "", headers: ["Content-Disposition": "attachment; filename*=UTF-8''%E6%88%91%E7%9A%84%E8%AE%A2%E9%98%85"]).title == "我的订阅")
        let encoded = "base64:" + Data("机场 Pro".utf8).base64EncodedString()
        #expect(SubscriptionResponse(text: "", headers: ["profile-title": encoded, "Content-Disposition": "attachment; filename=x.yaml"]).title == "机场 Pro")
        #expect(SubscriptionResponse(text: "", headers: [:]).title == nil)
    }

    @Test func parsesUsageAndInterval() {
        let response = SubscriptionResponse(text: "", headers: ["Subscription-Userinfo": "upload=1024; download=2048; total=1073741824; expire=1798761600",
                                                               "profile-update-interval": "24"])
        #expect(response.usage?.used == 3072 && response.usage?.total == 1_073_741_824)
        #expect(response.usage?.expire == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(response.updateIntervalHours == 24)
        #expect(SubscriptionUsage.parse("expire=0") == nil)
    }
}

struct SubscriptionLinkTests {
    @Test func httpIsAllowedOnlyForLoopbackAndPrivateHosts() throws {
        for allowed in ["http://127.0.0.1:3000/download/sub", "http://localhost:3000/download/sub", "http://[::1]:3000/download/sub",
                        "http://127.8.9.1/x", "http://10.0.0.5/x", "http://172.16.0.1/x", "http://172.31.255.255/x",
                        "http://192.168.1.10:3001/x", "http://nas.local/x", "HTTP://192.168.1.10/x", "https://sub.example.invalid/api?token=1"] {
            #expect((try? SubscriptionFetcher.validate(allowed)) != nil, "\(allowed)")
        }
        for rejected in ["http://sub.example.invalid/x", "http://8.8.8.8/x", "http://172.32.0.1/x", "http://172.15.0.1/x",
                         "http://192.169.1.1/x", "http://10.0.0.1.example.com/x", "http://localhost.example.com/x",
                         "http://.local/x", "http://10.1/x", "http://256.0.0.1/x", "http://0x7f.0.0.1/x", "http://[::2]/x",
                         "ftp://127.0.0.1/x", "file:///etc/hosts", "nonsense"] {
            #expect(throws: EditorError.self, "\(rejected)") { try SubscriptionFetcher.validate(rejected) }
        }
    }

    @Test func httpLinksNeedAPathSoProxyShareLinksStayContent() {
        #expect(SubscriptionFetcher.looksLikeLink("http://127.0.0.1:3000/download/sub"))
        #expect(SubscriptionFetcher.looksLikeLink("http://sub.example.invalid/api?token=1"))
        #expect(!SubscriptionFetcher.looksLikeLink("http://192.168.1.2:7890#LAN"))
        #expect(!SubscriptionFetcher.looksLikeLink("http://user:pass@1.2.3.4:8080/"))
    }

    @Test func subStoreDownloadsGetTheMihomoTarget() throws {
        #expect(try SubscriptionFetcher.validate("http://127.0.0.1:3000/download/my-sub").absoluteString
                == "http://127.0.0.1:3000/download/my-sub?target=mihomo")
        #expect(try SubscriptionFetcher.validate("http://192.168.1.2:3000/download/collection/all?ua=x%2By").absoluteString
                == "http://192.168.1.2:3000/download/collection/all?ua=x%2By&target=mihomo")
        #expect(try SubscriptionFetcher.validate("http://127.0.0.1:3000/download/sub?target=").absoluteString
                == "http://127.0.0.1:3000/download/sub?target=mihomo")
        // Behind a backend path prefix.
        #expect(try SubscriptionFetcher.validate("https://sub.example.invalid/secret/download/sub").absoluteString
                == "https://sub.example.invalid/secret/download/sub?target=mihomo")
        // A target already chosen, in the query or the path, is kept.
        for kept in ["http://127.0.0.1:3000/download/sub?target=ClashMeta", "http://127.0.0.1:3000/download/sub/ClashMeta",
                     "https://example.invalid/files/download/a/b/c.yaml", "https://example.invalid/a/b/download/sub",
                     "https://example.invalid/api/v1/client/subscribe?token=1"] {
            #expect(try SubscriptionFetcher.validate(kept).absoluteString == kept)
        }
    }

    @Test func subStoreNamesComeFromThePath() throws {
        let single = try #require(SubscriptionFetcher.subStoreDownload(URL(string: "http://127.0.0.1:3000/download/%E6%9C%BA%E5%9C%BA?target=mihomo")!))
        #expect(single == .init(name: "机场", isCollection: false, target: "mihomo"))
        let collection = try #require(SubscriptionFetcher.subStoreDownload(URL(string: "http://127.0.0.1:3000/download/collection/all/ClashMeta")!))
        #expect(collection == .init(name: "all", isCollection: true, target: "ClashMeta"))
        #expect(SubscriptionFetcher.subStoreDownload(URL(string: "http://127.0.0.1:3000/download/")!) == nil)
        #expect(SubscriptionFetcher.subStoreDownload(URL(string: "https://sub.example.invalid/api/v1/client/subscribe")!) == nil)
    }
}

struct ProfileAnalysisTests {
    @Test func summarizesTheSample() throws {
        let analysis = try #require(ProfileAnalysis.analyze(SampleConfig.text))
        #expect(analysis.proxyCount == 5 && analysis.groupCount == 4 && analysis.ruleCount == 8 && analysis.ruleProviderCount == 0)
        #expect(analysis.protocols == [.init(label: "SS", count: 5)])
        #expect(analysis.groupTypes == [.init(label: "Select", count: 3), .init(label: "URLTest", count: 1)])
        #expect(analysis.ruleTargets.first == .init(label: "DIRECT", count: 5))
        let auto = try #require(analysis.groups.first { $0.name == "自动选择" })
        #expect(auto.referenceCount == 2 && auto.members.allSatisfy { $0.kind == .proxy })
    }

    @Test func handlesLogicalRulesProvidersAndMissingMembers() throws {
        let yaml = """
        proxy-providers:
          sub: {type: http, url: 'https://x.invalid', path: ./a.yaml}
        proxy-groups:
          - {name: G, type: fallback, use: [sub], proxies: [Ghost, DIRECT], include-all: true}
        rules:
          - AND,((DOMAIN,a.com),(NETWORK,UDP)),G
          - MATCH,G
        """
        let analysis = try #require(ProfileAnalysis.analyze(yaml))
        #expect(analysis.ruleTypes.map(\.label).sorted() == ["AND", "MATCH"])
        #expect(analysis.ruleTargets == [.init(label: "G", count: 2)])
        #expect(analysis.providers == [.init(name: "sub", type: "http")])
        let group = try #require(analysis.groups.first)
        #expect(group.type == "Fallback" && group.includesAll && group.providers == ["sub"])
        #expect(group.members.map(\.kind) == [.missing, .builtin])
    }

    @Test func foldsIntoOtherAndFormatsPercent() {
        let counts = (1...8).map { ProfileAnalysis.Count(label: "T\($0)", count: 9 - $0) }
        let folded = counts.top(5)
        #expect(folded.top.count == 5 && folded.otherCount == 3 + 2 + 1 && folded.otherLabels == 3)
        #expect(percentLabel(1, of: 364) == "<1%" && percentLabel(225, of: 364) == "62%" && percentLabel(0, of: 0) == "0%")
    }
}
