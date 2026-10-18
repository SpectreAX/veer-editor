import Foundation
import Testing
@testable import VeerCore

/// Runs only when VEER_MIHOMO_BIN points at a Mihomo binary.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct RealValidatorTests {
    @Test func validatesSampleAndCandidate() async throws {
        let validator = MihomoValidator()
        #expect(await validator.validate(SampleConfig.text).status == .passed)
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: doc.target(named: "日本出口")!.id)])
        let candidate = try PlanApplier.apply(plan, to: doc).candidate
        #expect(await validator.validate(candidate).status == .passed)
        let broken = await validator.validate(SampleConfig.text.replacingOccurrences(of: "MATCH,自动选择", with: "MATCH,不存在的组"))
        #expect(broken.status == .failed)
        #expect(!(broken.detail ?? "").contains("placeholder-password"))
    }

    /// A plan that creates a group must still pass Mihomo.
    @Test func newGroupsPassMihomo() async throws {
        let doc = try GroupFixture.document()
        guard case .plan(let plan) = try LocalIntentParser.parse("巴哈姆特走台湾和香港", targets: doc.targets, regions: GroupFixture.regions(doc)) else {
            Issue.record("expected plan"); return
        }
        let candidate = try PlanApplier.apply(plan, to: doc, regions: GroupFixture.regions(doc)).candidate
        let check = await MihomoValidator().validate(candidate)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }

    @Test func editedUrlTestGroupsPassMihomo() async throws {
        let doc = try GroupFixture.document()
        let plan = EditPlan(operations: [.group(.init(id: "new-1", name: "巴哈", type: "url-test", members: [doc.target(named: "🇭🇰 香港 01")!.id])),
                                         .route(matchType: "DOMAIN-SUFFIX", match: "gamer.com.tw", targetId: "new-1")])
        let candidate = try PlanApplier.apply(plan, to: doc).candidate
        #expect(candidate.contains("type: url-test\n    url: https://www.gstatic.com/generate_204\n    interval: 300\n"))
        let check = await MihomoValidator().validate(candidate)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }

    /// Configs generated from share links must pass Mihomo's own parser.
    @Test func generatedConfigsPassMihomo() async throws {
        let validator = MihomoValidator()
        let result = try ConfigImporter.normalize(Links.all)
        let check = await validator.validate(result.text)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
        let cleaned = try ConfigImporter.normalize(NodeCleanupTests.subscription, options: .init(addRegionFlags: true))
        #expect(!cleaned.cleanup.isEmpty)
        let cleanedCheck = await validator.validate(cleaned.text)
        #expect(cleanedCheck.status == .passed, "\(cleanedCheck.message) \(cleanedCheck.detail ?? "")")
    }
}
