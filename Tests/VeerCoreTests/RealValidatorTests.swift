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

    /// Configs generated from share links must pass Mihomo's own parser.
    @Test func generatedConfigsPassMihomo() async throws {
        let validator = MihomoValidator()
        let result = try ConfigImporter.normalize(Links.all)
        let check = await validator.validate(result.text)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }
}
