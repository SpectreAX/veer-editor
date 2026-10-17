import Foundation
import Testing
@testable import VeerCore
@testable import VeerEditorApp

struct PassValidator: ConfigValidating {
    func validate(_ yaml: String) async -> ValidationResult {
        try? await Task.sleep(for: .milliseconds(50))
        return .init(status: .passed, message: "ok")
    }
    var versionDescription: String? { "test" }
}

struct VerifiedAll: RuleSetVerifying {
    func verify(_ urls: [String]) async -> [String: RuleSetVerification] { Dictionary(uniqueKeysWithValues: urls.map { ($0, .verified) }) }
}

@MainActor
struct StoreTests {
    func makeStore() -> EditorStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EditorStore(store: SessionStore(directory: directory), keyStore: MemoryKeyStore(),
                                engine: EditorEngine(validator: PassValidator(), verifier: VerifiedAll()), persist: false)
        store.useAI = false
        store.loadSample()
        store.confirmExits()
        return store
    }

    func waitIdle(_ store: EditorStore) async {
        for _ in 0..<200 where store.isRunning || !store.revalidating.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func writeUndoRedoKeepsTurnStatusInStep() async throws {
        let store = makeStore()
        store.send("Netflix 走日本，ChatGPT 走美国")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        #expect(turn.proposal?.items.count == 2)
        #expect(store.canWrite(turn))

        store.write()
        #expect(store.current?.turns.last?.proposal?.status == .written)
        #expect(store.current?.hasUnexportedChanges == true)
        #expect(store.draft?.rules.prefix(2) == ["RULE-SET,netflix,日本出口", "RULE-SET,openai,美国出口"])

        store.undo()
        #expect(store.current?.draftText == SampleConfig.text)
        #expect(store.current?.turns.first?.proposal?.status == .undone)
        #expect(store.current?.turns.last?.isNote == true)

        store.redo()
        #expect(store.current?.turns.first?.proposal?.status == .written)
        #expect(store.draft?.rules.first == "RULE-SET,netflix,日本出口")
    }

    @Test func candidatesFromAnOlderDraftCannotBeWrittenUntilTheDraftMatchesAgain() async throws {
        let store = makeStore()
        store.send("YouTube 走香港")
        await waitIdle(store)
        store.send("example.org 直连")
        await waitIdle(store)
        let first = try #require(store.current?.turns.first), second = try #require(store.current?.turns.last)
        store.write(turnID: second.id)
        #expect(!store.canWrite(store.current!.turns.first!))
        #expect(first.proposal?.status == .pending)
        store.undo()
        #expect(store.canWrite(store.current!.turns.first!))
    }

    @Test func writingWaitsForRevalidationAndUsesTheAcceptedSubset() async throws {
        let store = makeStore()
        store.send("Netflix 走日本，ChatGPT 走美国")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        store.setAccepted(false, item: 1, turnID: turn.id)
        #expect(!store.canWrite(store.current!.turns.last!))
        store.write(turnID: turn.id)
        #expect(store.current?.turns.last?.proposal?.status == .pending)
        await waitIdle(store)
        store.write(turnID: turn.id)
        #expect(store.draft?.rules.first == "RULE-SET,netflix,日本出口")
        #expect(store.draft?.providers.map(\.key) == ["netflix"])
        #expect(store.draft?.rules.contains("DOMAIN-SUFFIX,openai.com,DIRECT") == true)
    }

    @Test func outOfScopeAndClarificationNeverChangeTheDraft() async {
        let store = makeStore()
        store.send("节点太卡了换一个")
        await waitIdle(store)
        store.send("YouTube 走代理")
        await waitIdle(store)
        #expect(store.current?.turns.map(\.outcome).contains(.outOfScope(LocalIntentParser.outOfScopeMessage)) == true)
        if case .clarification(_, let options) = store.current?.turns.last?.outcome { #expect(!options.isEmpty) } else { Issue.record("expected clarification") }
        #expect(store.current?.draftText == SampleConfig.text)
    }

    @Test func aiFailuresOfferRecoveryAndPayloadIsAnonymous() async throws {
        let store = makeStore()
        store.useAI = true
        store.sessionKey = "sk-test-secret"
        store.settings.baseURL = "http://example.com/v1"
        store.send("Netflix 走日本出口")
        await waitIdle(store)
        let turn = try #require(store.current?.turns.last)
        guard case let .failure(message, opensSettings, canUseLocal) = turn.outcome else { Issue.record("expected failure"); return }
        #expect(message.contains("HTTPS"))
        #expect(opensSettings && canUseLocal)
        let payload = try #require(turn.sentPayload).readable
        #expect(payload.contains("出口1（日本）"))
        #expect(!payload.contains("日本出口") && !payload.contains("sk-test") && !payload.contains("password"))
    }

    @Test func exportRefusesTheOriginalFileAndWritesTheDraft() async throws {
        let store = makeStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("config.yaml")
        try SampleConfig.text.write(to: source, atomically: true, encoding: .utf8)
        store.importFile(source)
        store.confirmExits()
        let link = directory.appendingPathComponent("alias.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: EditorError.self) { try await store.export(to: link, validate: false) }

        store.send("example.org 直连")
        await waitIdle(store)
        store.write()
        let out = directory.appendingPathComponent("out.yaml")
        try await store.export(to: out, validate: true)
        #expect(try String(contentsOf: out, encoding: .utf8) == store.current?.draftText)
        #expect(store.current?.hasUnexportedChanges == false)
        #expect(try String(contentsOf: source, encoding: .utf8) == SampleConfig.text)
    }

    @Test func commandsRouteToTheInspector() {
        let store = makeStore()
        store.send("/test www.example.com")
        #expect(store.inspectorTab == .test && store.testQuery == "www.example.com")
        #expect(store.current?.turns.isEmpty == true)
    }
}
