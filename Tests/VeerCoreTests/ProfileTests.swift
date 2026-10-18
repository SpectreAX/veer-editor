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
