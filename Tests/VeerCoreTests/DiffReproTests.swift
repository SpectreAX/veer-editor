import Testing
@testable import VeerCore

struct DiffReproTests {
    @Test func secondRuleSetDiffIsMinimal() throws {
        let doc = try ConfigDocument.parse(SampleConfig.text)
        let jp = doc.target(named: "日本出口")!.id, us = doc.target(named: "美国出口")!.id
        let first = try PlanApplier.apply(EditPlan(operations: [
            .ruleSet(.catalog(source: "metacubex-geosite", name: "netflix"), targetId: jp),
            .ruleSet(.catalog(source: "metacubex-geosite", name: "openai"), targetId: us),
        ]), to: doc).candidate
        let second = try PlanApplier.apply(EditPlan(operations: [.ruleSet(.catalog(source: "metacubex-geosite", name: "spotify"), targetId: us)]),
                                           to: try ConfigDocument.parse(first)).candidate
        let added = LineDiff.diff(first, second).filter { $0.kind != .same }
        #expect(added.allSatisfy { $0.kind == .added })
        #expect(added.count == 8)
        #expect(added.last?.text == "  - RULE-SET,spotify,美国出口")
    }
}
