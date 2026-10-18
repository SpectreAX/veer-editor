import AppKit
import Observation
import SwiftUI
import VeerCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes, rules, test, exits
    var id: String { rawValue }
    var title: String {
        switch self {
        case .changes: "变更"
        case .rules: "规则"
        case .test: "测试"
        case .exits: "出口"
        }
    }
}

enum DiffScope: String, CaseIterable, Identifiable {
    case turn, original
    var id: String { rawValue }
    var title: String { self == .turn ? "本轮" : "相对原始配置" }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    var undoable = false
}

/// App state. One instance per window scene; all mutation happens on the main actor.
@Observable
final class EditorStore {
    var sessions: [Session] = []
    var selectedID: UUID?
    var showingStart = false
    var inspectorPresented = true
    var inspectorTab: InspectorTab = .changes
    var inspectedTurnID: UUID?
    var diffScope: DiffScope = .turn
    var toast: Toast?
    var importError: String?
    var importing = false
    var showingSubscriptionSheet = false
    var showingPasteSheet = false
    var showingExportSheet = false
    var showingSettings = false
    var payloadTurnID: UUID?
    var pendingDeletion: Session?
    var composerText = ""
    var composerFocusToken = 0

    var settings: AISettings { didSet { saveSettings() } }
    var useAI: Bool { didSet { UserDefaults.standard.set(useAI, forKey: "useAI") } }
    var validateBeforeExport: Bool { didSet { UserDefaults.standard.set(validateBeforeExport, forKey: "validateBeforeExport") } }
    /// Key used only for this app run when the user chose not to save it.
    var sessionKey: String?
    var keySaved: Bool

    let store: SessionStore
    let keyStore: KeyStoring
    let engine: EditorEngine
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var documentCache: [String: ConfigDocument] = [:]
    @ObservationIgnored private var saveWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    init(store: SessionStore = SessionStore(), keyStore: KeyStoring = KeychainKeyStore(), engine: EditorEngine = EditorEngine(), persist: Bool = true) {
        self.store = store
        self.keyStore = keyStore
        self.engine = engine
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "aiSettings"), let saved = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = saved
        } else {
            settings = AISettings()
        }
        useAI = defaults.object(forKey: "useAI") as? Bool ?? false
        validateBeforeExport = defaults.object(forKey: "validateBeforeExport") as? Bool ?? true
        keySaved = keyStore.read() != nil
        if persist {
            sessions = store.loadAll()
            selectedID = sessions.first?.id
        }
        showingStart = sessions.isEmpty
    }

    // MARK: Derived state

    var current: Session? {
        get { sessions.first { $0.id == selectedID } }
        set {
            guard let newValue, let index = sessions.firstIndex(where: { $0.id == newValue.id }) else { return }
            sessions[index] = newValue
            scheduleSave(newValue)
        }
    }

    func document(for text: String) -> ConfigDocument? {
        if let cached = documentCache[text] { return cached }
        guard let parsed = try? ConfigDocument.parse(text) else { return nil }
        if documentCache.count > 24 { documentCache.removeAll() }
        documentCache[text] = parsed
        return parsed
    }

    var draft: ConfigDocument? { current.flatMap { document(for: $0.draftText) } }
    var original: ConfigDocument? { current.flatMap { document(for: $0.originalText) } }

    var regions: [String: Region] {
        guard let current, let draft else { return [:] }
        return current.regions(for: draft.targets)
    }

    var isRunning: Bool { current.map { tasks[$0.id] != nil } ?? false }

    var apiKey: String? { sessionKey ?? keyStore.read() }
    var aiConfigured: Bool { !settings.preset.needsKey || keySaved || sessionKey != nil }
    var effectiveUseAI: Bool { useAI && aiConfigured }

    var subtitle: String {
        guard let current else { return "" }
        if !current.exitsConfirmed { return "确认出口" }
        guard current.hasUnexportedChanges, let original = original, let draft else {
            return current.exportedText == nil ? "与原始配置一致" : "已导出 · 没有新的修改"
        }
        let changed = changedRuleCount(from: original, to: draft)
        return "草稿 · \(changed) 项未导出修改"
    }

    func changedRuleCount(from original: ConfigDocument, to draft: ConfigDocument) -> Int {
        let before = Set(original.rules), after = Set(draft.rules)
        return max(after.subtracting(before).count, before.subtracting(after).count)
    }

    /// Rules added in this session, for the "新增" marker.
    var addedRules: Set<String> {
        guard let original, let draft else { return [] }
        return Set(draft.rules).subtracting(original.rules)
    }

    var latestProposalTurnID: UUID? {
        current?.turns.last { $0.proposal != nil }?.id
    }

    // MARK: Import

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) > ConfigDocument.maxBytes { throw EditorError("配置超过 2 MB，请先拆分后再导入。") }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw EditorError("文件不是 UTF-8 文本。") }
            try addSession(title: url.lastPathComponent, source: .file(name: url.lastPathComponent, path: url.path), text: text)
        } catch {
            importError = message(for: error)
        }
    }

    func importText(_ text: String) {
        do { try addSession(title: "粘贴的配置", source: .pasted, text: text); showingPasteSheet = false }
        catch { importError = message(for: error) }
    }

    func loadSample() {
        do { try addSession(title: SampleConfig.title, source: .sample, text: SampleConfig.text) }
        catch { importError = message(for: error) }
    }

    func importSubscription(_ raw: String) async {
        importing = true
        importError = nil
        defer { importing = false }
        do {
            let url = try SubscriptionFetcher.validate(raw)
            let text = try await SubscriptionFetcher().fetch(url)
            try addSession(title: url.host ?? "订阅", source: .subscription(host: url.host ?? ""), text: text)
            showingSubscriptionSheet = false
        } catch {
            importError = message(for: error)
        }
    }

    /// Detects the format (Mihomo YAML, node list, Base64 subscription, share links) and converts
    /// to a full Mihomo configuration when needed.
    private func addSession(title: String, source: Session.Source, text: String) throws {
        let imported = try ConfigImporter.normalize(text)
        _ = try ConfigDocument.parse(imported.text)
        var session = Session(title: title, source: source, text: imported.text)
        session.importNote = imported.note
        sessions.insert(session, at: 0)
        selectedID = session.id
        showingStart = false
        importError = nil
        inspectedTurnID = nil
        scheduleSave(session, immediately: true)
    }

    func confirmExits() {
        guard var session = current else { return }
        session.exitsConfirmed = true
        current = session
        composerFocusToken += 1
    }

    func setRegion(_ region: Region, for name: String) {
        guard var session = current else { return }
        session.regionOverrides[name] = region
        current = session
    }

    // MARK: Conversation

    func send(_ raw: String? = nil) {
        let prompt = (raw ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, var session = current, let draft, !isRunning else { return }
        if raw == nil { composerText = "" }
        if handleCommand(prompt) { return }

        let useAI = effectiveUseAI
        let mode: Turn.Mode = useAI ? .ai(model: settings.model) : .local
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        var turn = Turn(prompt: prompt, mode: mode, steps: steps)
        let request = EditorEngine.Request(prompt: prompt, draft: draft, regions: session.regions(for: draft.targets), useAI: useAI,
                                           settings: settings, apiKey: apiKey, history: history(for: session, context: draft))
        if useAI { turn.sentPayload = EditorEngine.payload(for: request) }
        invalidatePending(in: &session)
        session.turns.append(turn)
        session.updatedAt = .now
        current = session

        let sessionID = session.id, turnID = turn.id
        let started = Date()
        let engine = engine
        tasks[sessionID] = Task { [weak self] in
            do {
                let output = try await engine.run(request) { event in
                    await MainActor.run { self?.apply(event, sessionID: sessionID, turnID: turnID) }
                }
                self?.finish(sessionID: sessionID, turnID: turnID, started: started, draftText: draft.text, output: output)
            } catch {
                self?.fail(sessionID: sessionID, turnID: turnID, started: started, error: error)
            }
        }
    }

    private func handleCommand(_ prompt: String) -> Bool {
        guard prompt.hasPrefix("/") else { return false }
        let parts = prompt.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "/test":
            inspectorPresented = true
            inspectorTab = .test
            testQuery = parts.count > 1 ? parts[1] : ""
        case "/undo": undo()
        case "/redo": redo()
        case "/export": requestExport()
        case "/rules": inspectorPresented = true; inspectorTab = .rules
        default:
            showToast("未知命令 \(parts[0])。可用：/test、/undo、/redo、/export、/rules")
        }
        return true
    }

    var testQuery = ""
    /// Turns whose candidate is being rebuilt after an accept/reject toggle; writing waits.
    var revalidating: Set<UUID> = []

    /// Earlier exchanges in anonymized form, so follow-ups like "那走香港" resolve.
    private func history(for session: Session, context draft: ConfigDocument) -> [(role: String, content: String)] {
        let anon = AnonymousContext(targets: draft.targets, regions: session.regions(for: draft.targets))
        var messages: [(String, String)] = []
        for turn in session.turns.suffix(6) where !turn.isNote {
            let reply: String
            switch turn.outcome {
            case .proposal(let proposal):
                let summary = proposal.items.filter { proposal.accepted.contains($0.id) }.map { item in
                    "\(item.subject) → \(item.targetID.flatMap(anon.label(forTargetID:)) ?? "删除")"
                }.joined(separator: "；")
                reply = "\(proposal.status == .written ? "已写入草稿" : "已提出修改")：\(summary)"
            case .clarification(let question, _): reply = question
            case .outOfScope(let text), .noChange(let text): reply = text
            default: continue
            }
            messages.append(("user", anon.anonymize(turn.prompt)))
            messages.append(("assistant", reply))
        }
        return messages
    }

    private func apply(_ event: EditorEngine.Progress, sessionID: UUID, turnID: UUID) {
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            switch event {
            case .started(let index):
                turn.steps[index].state = .running
            case .finished(let index, let detail):
                turn.steps[index].state = .done
                turn.steps[index].detail = detail
            }
        }
    }

    private func finish(sessionID: UUID, turnID: UUID, started: Date, draftText: String, output: EditorEngine.Output) {
        tasks[sessionID] = nil
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            turn.duration = Date().timeIntervalSince(started)
            for index in turn.steps.indices where turn.steps[index].state == .waiting { turn.steps.removeSubrange(index...); break }
            switch output {
            case let .proposal(plan, items, candidate, validation):
                turn.outcome = .proposal(.init(plan: plan, items: items, accepted: Set(items.map(\.id)), baseDraft: draftText,
                                               candidate: candidate, validation: validation, status: .pending))
            case .noChange(let text): turn.outcome = .noChange(text)
            case let .clarification(question, suggestions): turn.outcome = .clarification(question, suggestions: suggestions)
            case .outOfScope(let text): turn.outcome = .outOfScope(text)
            }
        }
        if case .proposal = output {
            inspectedTurnID = turnID
            diffScope = .turn
        }
        announce("处理完成")
    }

    private func fail(sessionID: UUID, turnID: UUID, started: Date, error: Error) {
        tasks[sessionID] = nil
        mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
            turn.duration = Date().timeIntervalSince(started)
            let cancelled = error is CancellationError || (error as? AIFailure) == .cancelled
            for index in turn.steps.indices where [.running, .waiting].contains(turn.steps[index].state) {
                turn.steps[index].state = cancelled ? .cancelled : (turn.steps[index].state == .running ? .failed : .cancelled)
            }
            if cancelled { turn.outcome = .cancelled; return }
            let failure = error as? AIFailure
            turn.outcome = .failure(message: message(for: error), opensSettings: failure?.opensSettings ?? false, canUseLocal: turn.mode != .local)
        }
    }

    func cancel() {
        guard let id = current?.id else { return }
        tasks[id]?.cancel()
    }

    private func mutateTurn(sessionID: UUID, turnID: UUID, _ change: (inout Turn) -> Void) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let turnIndex = sessions[sessionIndex].turns.firstIndex(where: { $0.id == turnID }) else { return }
        change(&sessions[sessionIndex].turns[turnIndex])
        sessions[sessionIndex].updatedAt = .now
        scheduleSave(sessions[sessionIndex])
    }

    /// A pending candidate built from an older draft can no longer be written.
    /// Staleness is derived (a pending proposal whose base differs from the draft), so undoing
    /// back to that base makes it writable again. Nothing to store here.
    private func invalidatePending(in session: inout Session) {}

    func setAccepted(_ accepted: Bool, item: Int, turnID: UUID) {
        guard let session = current, let draft,
              let turn = session.turns.first(where: { $0.id == turnID }), var proposal = turn.proposal, proposal.status == .pending else { return }
        if accepted { proposal.accepted.insert(item) } else { proposal.accepted.remove(item) }
        let accepted = proposal.accepted
        mutateTurn(sessionID: session.id, turnID: turnID) { $0.proposal?.accepted = accepted }
        let engine = engine, plan = proposal.plan, items = proposal.items, sessionID = session.id
        revalidating.insert(turnID)
        Task { [weak self] in
            defer { if self?.current?.turns.first(where: { $0.id == turnID })?.proposal?.accepted == accepted { self?.revalidating.remove(turnID) } }
            do {
                let result = try await engine.reapply(plan: plan, accepted: accepted, draft: draft, previous: items)
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    guard turn.proposal?.accepted == accepted else { return }
                    turn.proposal?.candidate = result.candidate
                    turn.proposal?.validation = result.validation
                }
            } catch {
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    turn.proposal?.validation = ValidationResult(status: .failed, message: self?.message(for: error) ?? "")
                }
            }
        }
    }

    func canWrite(_ turn: Turn) -> Bool {
        guard let proposal = turn.proposal, proposal.status == .pending, let session = current else { return false }
        return !proposal.accepted.isEmpty && proposal.validation.status != .failed && proposal.baseDraft == session.draftText && !isRunning && !revalidating.contains(turn.id)
    }

    func write(turnID: UUID? = nil) {
        guard var session = current, let id = turnID ?? latestProposalTurnID,
              let index = session.turns.firstIndex(where: { $0.id == id }),
              var proposal = session.turns[index].proposal, canWrite(session.turns[index]) else { return }
        session.undoStack.append(session.draftText)
        session.redoStack.removeAll()
        proposal.writtenFrom = session.draftText
        proposal.writtenTo = proposal.candidate
        proposal.status = .written
        session.draftText = proposal.candidate
        session.turns[index].proposal = proposal
        session.updatedAt = .now
        invalidatePending(in: &session)
        current = session
        let count = proposal.accepted.count
        showToast("已写入草稿 \(count) 项，尚未导出", undoable: true)
        announce("已写入草稿")
    }

    func discard(turnID: UUID) {
        guard let session = current else { return }
        mutateTurn(sessionID: session.id, turnID: turnID) { turn in
            if turn.proposal?.status == .pending { turn.proposal?.status = .discarded }
        }
    }

    var canUndo: Bool { !(current?.undoStack.isEmpty ?? true) && !isRunning }
    var canRedo: Bool { !(current?.redoStack.isEmpty ?? true) && !isRunning }

    func undo() {
        guard var session = current, let previous = session.undoStack.popLast(), !isRunning else { return }
        session.redoStack.append(session.draftText)
        markWrite(in: &session, from: previous, to: session.draftText, as: .undone)
        session.draftText = previous
        session.turns.append(Turn(prompt: "", mode: .local, steps: [], outcome: .note("已撤销上一次写入，草稿恢复到之前的状态。")))
        invalidatePending(in: &session)
        current = session
        showToast("已撤销")
        announce("已撤销")
    }

    func redo() {
        guard var session = current, let next = session.redoStack.popLast(), !isRunning else { return }
        session.undoStack.append(session.draftText)
        markWrite(in: &session, from: session.draftText, to: next, as: .written)
        session.draftText = next
        session.turns.append(Turn(prompt: "", mode: .local, steps: [], outcome: .note("已重做写入。")))
        invalidatePending(in: &session)
        current = session
        showToast("已重做")
    }

    /// Keeps a turn's status in step with undo/redo of the write it made.
    private func markWrite(in session: inout Session, from: String, to: String, as status: Turn.ProposalStatus) {
        guard let index = session.turns.lastIndex(where: { $0.proposal?.writtenFrom == from && $0.proposal?.writtenTo == to }) else { return }
        session.turns[index].proposal?.status = status
    }

    func retry(turnID: UUID, useLocal: Bool = false) {
        guard let turn = current?.turns.first(where: { $0.id == turnID }) else { return }
        if useLocal { useAI = false }
        send(turn.prompt)
    }

    // MARK: Inspector

    func showDiff(for turnID: UUID) {
        inspectedTurnID = turnID
        diffScope = .turn
        inspectorTab = .changes
        inspectorPresented = true
    }

    /// Old and new text for the inspector's change view.
    var diffTexts: (old: String, new: String)? {
        guard let session = current else { return nil }
        if diffScope == .original { return (session.originalText, session.draftText) }
        let turn = session.turns.first { $0.id == (inspectedTurnID ?? latestProposalTurnID) }
        guard let proposal = turn?.proposal else { return nil }
        if proposal.status == .written || proposal.status == .undone, let from = proposal.writtenFrom, let to = proposal.writtenTo { return (from, to) }
        return (proposal.baseDraft, proposal.candidate)
    }

    // MARK: Export

    func requestExport() {
        guard current != nil else { return }
        showingExportSheet = true
    }

    func export(to url: URL, validate: Bool) async throws {
        guard var session = current else { return }
        if case .file(_, let path) = session.source, Self.sameFile(url, URL(fileURLWithPath: path)) {
            throw EditorError("不能覆盖导入的原始文件，请另存为新文件。")
        }
        if validate {
            let result = await engine.validator.validate(session.draftText)
            if result.status == .failed { throw EditorError("\(result.message)\n\(result.detail ?? "")") }
        }
        try Data(session.draftText.utf8).write(to: url, options: .atomic)
        session.exportedText = session.draftText
        current = session
        showToast("已导出到 \(url.lastPathComponent)")
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ra = a.resolvingSymlinksInPath(), rb = b.resolvingSymlinksInPath()
        if ra.path == rb.path { return true }
        let ia = try? ra.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let ib = try? rb.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let ia, let ib { return ia.isEqual(ib) }
        return false
    }

    var exportStats: (added: Int, removed: Int, providers: Int) {
        guard let session = current else { return (0, 0, 0) }
        let stats = LineDiff.stats(LineDiff.diff(session.originalText, session.draftText))
        let providers = (draft?.providers.count ?? 0) - (original?.providers.count ?? 0)
        return (stats.added, stats.removed, max(0, providers))
    }

    // MARK: Sessions

    func select(_ id: UUID) {
        selectedID = id
        showingStart = false
        inspectedTurnID = nil
    }

    func newImport() {
        showingStart = true
        selectedID = nil
    }

    func delete(_ session: Session) {
        tasks[session.id]?.cancel()
        sessions.removeAll { $0.id == session.id }
        store.delete(session.id)
        if selectedID == session.id { selectedID = sessions.first?.id }
        showingStart = sessions.isEmpty || selectedID == nil
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sessions[index].title = title
        scheduleSave(sessions[index])
    }

    func deleteAllSessions() {
        for task in tasks.values { task.cancel() }
        store.deleteAll()
        sessions = []
        selectedID = nil
        showingStart = true
    }

    var hasUnexportedSessions: Bool { sessions.contains { $0.hasUnexportedChanges } }

    // MARK: Settings & key

    func saveKey(_ key: String, remember: Bool) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if remember {
            try keyStore.save(trimmed)
            keySaved = true
            sessionKey = nil
        } else {
            sessionKey = trimmed
        }
    }

    func forgetKey() {
        keyStore.delete()
        keySaved = false
        sessionKey = nil
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "aiSettings") }
    }

    // MARK: Persistence & feedback

    private func scheduleSave(_ session: Session, immediately: Bool = false) {
        saveWork[session.id]?.cancel()
        let store = store
        let work = DispatchWorkItem { try? store.save(session) }
        saveWork[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.4), execute: work)
    }

    func flush() {
        for session in sessions { try? store.save(session) }
    }

    func showToast(_ message: String, undoable: Bool = false) {
        toastWork?.cancel()
        toast = Toast(message: message, undoable: undoable)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func message(for error: Error) -> String {
        if let editor = error as? EditorError { return editor.message }
        if let failure = error as? AIFailure { return failure.message }
        return "发生未知错误，请重试。"
    }
}
