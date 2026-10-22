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

struct GroupEditTarget: Identifiable, Equatable {
    let turnID: UUID
    let itemID: Int
    var id: String { "\(turnID)-\(itemID)" }
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
    var selectedID: UUID? {
        didSet { if selectedID != oldValue { olderTurnPages = 0; turnBaseline = current?.turns.count ?? 0 } }
    }
    /// Pages of older turns the user asked to see in the current session.
    var olderTurnPages = 0
    /// Turn count when the session was selected; turns added since are always shown.
    @ObservationIgnored private var turnBaseline = 0
    var showingStart = false
    // Lookup tools (rule sets, DNS, IP).
    var lookupTab: LookupTab = .ruleSets
    /// A query handed to a lookup tab (from another tab or the main window); the tab runs it.
    var lookupRequest: LookupRequest?
    var geoStatus: GeoDataStore.Status?
    var geoDownload: GeoDownloadState = .idle
    /// Source and name for the add-rule-set sheet, set by a lookup result.
    var ruleSetPrefill: RuleSetPrefill?
    var inspectorPresented = true
    var inspectorTab: InspectorTab = .changes
    var inspectedTurnID: UUID?
    var diffScope: DiffScope = .turn
    var toast: Toast?
    var showingImport = false
    var showingRuleSetSheet = false
    var showingOverview = false
    var importStage: ImportStage = .input
    var importInput = ""
    @ObservationIgnored private var importTask: Task<Void, Never>?
    var showingExportSheet = false
    var showingModelPopover = false
    var payloadTurnID: UUID? { didSet { if payloadTurnID == nil { payloadComparing = false } } }
    /// The payload sheet shows the side-by-side comparison instead of the sent text.
    var payloadComparing = false
    var pendingDeletion: Session?
    var composerText = ""
    var composerFocusToken = 0

    var settings: AISettings {
        didSet {
            saveSettings()
            if settings.provider != oldValue.provider { keySaved = keyStore.read(for: settings.provider.rawValue) != nil }
        }
    }
    var useAI: Bool { didSet { defaults.set(useAI, forKey: "useAI") } }
    var validateBeforeExport: Bool { didSet { defaults.set(validateBeforeExport, forKey: "validateBeforeExport") } }
    /// Send literal domains/IPs from existing rules to the AI instead of placeholders. Off by default.
    var shareRuleLiterals: Bool { didSet { defaults.set(shareRuleLiterals, forKey: "shareRuleLiterals") } }
    /// Whether and where the AI may search the web.
    var searchSettings: SearchSettings {
        didSet { if let data = try? JSONEncoder().encode(searchSettings) { defaults.set(data, forKey: "searchSettings") } }
    }
    /// Keys used only for this app run when the user chose not to save them, by service.
    private var sessionKeys: [AIProvider: String] = [:]
    /// The current service's key for this run only.
    var sessionKey: String? {
        get { sessionKeys[settings.provider] }
        set { sessionKeys[settings.provider] = newValue }
    }

    /// Whether a key is available for `service`, saved or held for this session only.
    func hasKey(for service: AIProvider) -> Bool {
        sessionKeys[service] != nil || keyStore.read(for: service.rawValue) != nil
    }
    /// Whether the current service has a saved key.
    var keySaved: Bool

    let store: SessionStore
    /// Downloaded geodata for the lookup tools and AI search.
    let geo: GeoDataStore
    let keyStore: KeyStoring
    @ObservationIgnored let defaults: UserDefaults
    let engine: EditorEngine
    private var tasks: [UUID: Task<Void, Never>] = [:]
    // Derived-value caches. Not observed: they are filled while views render. Lookups compare
    // strings with == (O(1) when the storage is shared) instead of hashing whole configs.
    @ObservationIgnored private var documentCache: [(text: String, document: ConfigDocument)] = []
    @ObservationIgnored private var regionCache: (id: UUID, draft: String, overrides: [String: Region], value: [String: Region])?
    @ObservationIgnored private var addedCache: (original: String, draft: String, value: Set<String>)?
    @ObservationIgnored private var diffCache: [(old: String, new: String, lines: [DiffLine])] = []
    @ObservationIgnored private var structureCache: [(old: String, new: String, diff: ConfigDiff)] = []
    /// Changes tab: visual cards (default) or the YAML line diff.
    var changesVisual = true
    /// The new group being edited from a review card.
    var editingGroup: GroupEditTarget?
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "veer.session-save", qos: .utility)
    @ObservationIgnored private var saveWork: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var toastWork: DispatchWorkItem?

    init(store: SessionStore = SessionStore(), keyStore: KeyStoring = FileKeyStore(), engine: EditorEngine? = nil,
         geo: GeoDataStore = .shared, defaults: UserDefaults = .standard, persist: Bool = true) {
        self.store = store
        self.geo = geo
        self.keyStore = keyStore
        self.engine = engine ?? EditorEngine(searcher: WebSearchService(geo: geo), lookup: InstructionLookup(geo: geo))
        self.defaults = defaults
        var settings = AISettings()
        if let data = defaults.data(forKey: "aiSettings"), let saved = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = saved
        }
        // Thinking used to be a separate toggle with its own model.
        settings.migrateLegacy(deepThinking: defaults.bool(forKey: "deepThinking"))
        defaults.removeObject(forKey: "deepThinking")
        // Earlier snapshot runs wrote their unreachable test address into the real preferences.
        if settings.baseURL == Self.snapshotTestAddress { settings.baseURL = settings.provider.baseURL }
        self.settings = settings
        useAI = defaults.object(forKey: "useAI") as? Bool ?? false
        validateBeforeExport = defaults.object(forKey: "validateBeforeExport") as? Bool ?? true
        shareRuleLiterals = defaults.object(forKey: "shareRuleLiterals") as? Bool ?? false
        searchSettings = defaults.data(forKey: "searchSettings").flatMap { try? JSONDecoder().decode(SearchSettings.self, from: $0) } ?? SearchSettings()
        keySaved = keyStore.read(for: settings.provider.rawValue) != nil
        if persist {
            sessions = store.loadAll()
            selectedID = sessions.first?.id
            turnBaseline = sessions.first?.turns.count ?? 0
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
        if let index = documentCache.firstIndex(where: { $0.text == text }) {
            let hit = documentCache.remove(at: index)
            documentCache.insert(hit, at: 0)
            return hit.document
        }
        guard let parsed = try? ConfigDocument.parse(text) else { return nil }
        documentCache.insert((text, parsed), at: 0)
        if documentCache.count > 16 { documentCache.removeLast() }
        return parsed
    }

    /// Structural diff (groups, rules, rule sets) for the visual change view.
    func structure(_ old: String, _ new: String) -> ConfigDiff {
        // A few entries, so going back to a recent session does not parse and analyze it again.
        if let index = structureCache.firstIndex(where: { $0.old == old && $0.new == new }) {
            let hit = structureCache.remove(at: index)
            structureCache.insert(hit, at: 0)
            return hit.diff
        }
        let diff = ConfigDiff.compute(old: old, new: new)
        structureCache.insert((old, new, diff), at: 0)
        if structureCache.count > 8 { structureCache.removeLast() }
        return diff
    }

    /// Line diff, cached for the last few text pairs (the inspector re-renders often).
    func diff(_ old: String, _ new: String) -> [DiffLine] {
        if let hit = diffCache.first(where: { $0.old == old && $0.new == new }) { return hit.lines }
        let lines = LineDiff.diff(old, new)
        diffCache.insert((old, new, lines), at: 0)
        if diffCache.count > 4 { diffCache.removeLast() }
        return lines
    }

    /// Long sessions open with their newest turns only, so switching to one costs about the same
    /// as switching to a short one; older turns load a page at a time.
    static let turnPage = 10

    var visibleTurnCount: Int {
        Self.turnPage * (1 + olderTurnPages) + max(0, (current?.turns.count ?? 0) - turnBaseline)
    }

    var draft: ConfigDocument? { current.flatMap { document(for: $0.draftText) } }
    var original: ConfigDocument? { current.flatMap { document(for: $0.originalText) } }

    var regions: [String: Region] {
        guard let current, let draft else { return [:] }
        if let cache = regionCache, cache.id == current.id, cache.draft == current.draftText, cache.overrides == current.regionOverrides {
            return cache.value
        }
        let value = current.regions(for: draft.targets)
        regionCache = (current.id, current.draftText, current.regionOverrides, value)
        return value
    }

    var isRunning: Bool { current.map { tasks[$0.id] != nil } ?? false }

    var apiKey: String? { sessionKey ?? keyStore.read(for: settings.provider.rawValue) }
    var aiConfigured: Bool { !settings.provider.needsKey || keySaved || sessionKey != nil }
    var effectiveUseAI: Bool { useAI && aiConfigured }

    var subtitle: String {
        guard let current else { return "" }
        if !current.exitsConfirmed { return "确认出口" }
        guard current.hasUnexportedChanges, let original = original, let draft else {
            return current.exportedText == nil ? "与原始配置一致" : "已导出 · 没有新的修改"
        }
        let added = addedRules.count, removed = Set(original.rules).subtracting(draft.rules).count
        return "草稿 · \(max(added, removed)) 项未导出修改"
    }

    /// Rules added in this session, for the "新增" marker.
    var addedRules: Set<String> {
        guard let current, let original, let draft else { return [] }
        if let cache = addedCache, cache.original == current.originalText, cache.draft == current.draftText { return cache.value }
        let value = Set(draft.rules).subtracting(original.rules)
        addedCache = (current.originalText, current.draftText, value)
        return value
    }

    var latestProposalTurnID: UUID? {
        current?.turns.last { $0.proposal != nil }?.id
    }

    // MARK: Import

    /// One parsed import waiting for the user's confirmation in the preview panel.
    struct PendingImport: Identifiable {
        var id = UUID()
        var title: String
        var source: Session.Source
        var result: ConfigImporter.Result
        var analysis: ProfileAnalysis?
        var usage: SubscriptionUsage?
        /// Kept in memory only, for "刷新"; never persisted.
        var link: URL?
        var parsedAt = Date()
        /// Node clean-up for generated configs; changing it re-parses `rawText`.
        var options = ImportOptions()
        /// The downloaded or pasted content, kept in memory until the import is confirmed.
        var rawText = ""
    }

    enum ImportStage {
        case input
        case loading(String)
        case preview(PendingImport)
        case failed(String)
    }

    /// Opens the single import sheet. `prefill` is pasted content or a link.
    func openImport(prefill: String? = nil) {
        importInput = prefill ?? ""
        importStage = .input
        showingImport = true
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        showingImport = false
        importStage = .input
    }

    /// Parses whatever the user typed or pasted: a single subscription link is fetched,
    /// anything else is treated as configuration content.
    func submitImportInput() {
        let input = importInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if SubscriptionFetcher.looksLikeLink(input) {
            do { fetchSubscription(try SubscriptionFetcher.validate(input)) } catch { importStage = .failed(message(for: error)) }
        } else {
            prepareImport(text: input, title: "粘贴的配置", source: .pasted)
        }
    }

    func chooseImportFile() {
        let panel = NSOpenPanel()
        // Any file: subscriptions are often saved as .txt or without an extension; content decides.
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.message = "选择 Mihomo / Clash 配置、Base64 订阅或分享链接列表（最大 2 MB）"
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { prepareImport(file: url) }
    }

    func prepareImport(file url: URL) {
        showingImport = true
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) > ConfigDocument.maxBytes { throw EditorError("文件超过 2 MB，请先拆分后再导入。") }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw EditorError("文件不是 UTF-8 文本。") }
            prepareImport(text: text, title: url.lastPathComponent, source: .file(name: url.lastPathComponent, path: url.path))
        } catch {
            importStage = .failed(message(for: error))
        }
    }

    func prepareImport(text: String, title: String, source: Session.Source, usage: SubscriptionUsage? = nil, link: URL? = nil,
                       options: ImportOptions = .init()) {
        do {
            let result = try ConfigImporter.normalize(text, options: options)
            _ = try ConfigDocument.parse(result.text)
            importStage = .preview(PendingImport(title: title, source: source, result: result,
                                                 analysis: ProfileAnalysis.analyze(result.text), usage: usage, link: link,
                                                 options: options, rawText: text))
        } catch {
            importStage = .failed(message(for: error))
        }
    }

    /// Re-parses the previewed content with changed clean-up options; the preview stays in place.
    func setPendingImportOptions(_ options: ImportOptions) {
        guard case .preview(let pending) = importStage, pending.options != options else { return }
        prepareImport(text: pending.rawText, title: pending.title, source: pending.source, usage: pending.usage,
                      link: pending.link, options: options)
        if case .preview(var updated) = importStage {
            updated.id = pending.id
            updated.parsedAt = pending.parsedAt
            importStage = .preview(updated)
        }
    }

    func fetchSubscription(_ url: URL, options: ImportOptions = .init()) {
        importTask?.cancel()
        importStage = .loading("正在下载订阅…")
        showingImport = true
        importTask = Task { [weak self] in
            do {
                let response = try await SubscriptionFetcher().fetch(url)
                guard !Task.isCancelled else { return }
                let host = url.host ?? "订阅"
                let name = response.title ?? SubscriptionFetcher.subStoreDownload(url)?.name ?? host
                self?.prepareImport(text: response.text, title: name, source: .subscription(host: host),
                                    usage: response.usage, link: url, options: options)
            } catch {
                guard !Task.isCancelled else { return }
                self?.importStage = .failed(self?.message(for: error) ?? "")
            }
        }
    }

    func refreshPendingImport() {
        if case .preview(let pending) = importStage, let link = pending.link { fetchSubscription(link, options: pending.options) }
    }

    /// Creates the session from the previewed import.
    func confirmPendingImport() {
        guard case .preview(let pending) = importStage else { return }
        var session = Session(title: pending.title, source: pending.source, text: pending.result.text)
        session.importNote = pending.result.note
        session.subscriptionUsage = pending.usage
        sessions.insert(session, at: 0)
        selectedID = session.id
        showingStart = false
        inspectedTurnID = nil
        showingImport = false
        importStage = .input
        scheduleSave(session, immediately: true)
    }

    /// Parse and confirm in one step (used for pasted content in tests and snapshots).
    func importText(_ text: String, title: String = "粘贴的配置") {
        prepareImport(text: text, title: title, source: .pasted)
        if case .preview = importStage { confirmPendingImport() }
    }

    func loadSample() {
        prepareImport(text: SampleConfig.text, title: SampleConfig.title, source: .sample)
        confirmPendingImport()
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
        let mode: Turn.Mode = useAI ? .ai(model: settings.modelLabel) : .local
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        var turn = Turn(prompt: prompt, mode: mode, steps: steps)
        var request = EditorEngine.Request(prompt: prompt, draft: draft, regions: session.regions(for: draft.targets), useAI: useAI,
                                           settings: settings, apiKey: apiKey, history: history(for: session, context: draft),
                                           shareRuleLiterals: shareRuleLiterals)
        request.search = useAI ? searchConfig : nil
        if useAI { turn.sentPayload = EditorEngine.payload(for: request) }
        invalidatePending(in: &session)
        session.turns.append(turn)
        session.updatedAt = .now
        current = session

        let engine = engine, finalRequest = request
        startTurn(sessionID: session.id, turnID: turn.id, draftText: draft.text) { progress in
            try await engine.run(finalRequest, progress: progress)
        }
    }

    /// Adds an online rule set without parsing an instruction. It goes through the same URL
    /// check, apply, validation and review card as a conversational edit.
    func addRuleSet(_ reference: RuleSetReference, targetID: String) {
        guard var session = current, let draft, !isRunning, let target = draft.target(id: targetID) else { return }
        let label: String
        switch reference {
        case let .catalog(source, name): label = (try? RuleSetCatalog.spec(for: reference).sourceLabel) ?? "\(source)/\(name)"
        case let .url(url, _): label = url
        }
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .waiting) }
        let turn = Turn(prompt: "添加规则集 \(label) → \(target.name)", mode: .local, steps: steps)
        session.turns.append(turn)
        session.updatedAt = .now
        current = session
        let engine = engine, plan = EditPlan(operations: [.ruleSet(reference, targetId: targetID)]), regions = regions
        startTurn(sessionID: session.id, turnID: turn.id, draftText: draft.text) { progress in
            try await engine.run(plan: plan, draft: draft, regions: regions, progress: progress)
        }
    }

    private func startTurn(sessionID: UUID, turnID: UUID, draftText: String,
                           work: @escaping @Sendable (@escaping @Sendable (EditorEngine.Progress) async -> Void) async throws -> EditorEngine.Output) {
        let started = Date()
        tasks[sessionID] = Task { [weak self] in
            do {
                let output = try await work { event in
                    await MainActor.run { self?.apply(event, sessionID: sessionID, turnID: turnID) }
                }
                self?.finish(sessionID: sessionID, turnID: turnID, started: started, draftText: draftText, output: output)
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
        case "/ruleset": showingRuleSetSheet = true
        default:
            showToast("未知命令 \(parts[0])。可用：/test、/ruleset、/undo、/redo、/export、/rules")
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
                let summary = proposal.items.filter { proposal.accepted.contains($0.id) }.map { item -> String in
                    if let group = item.group { return "新建策略组“\(group.name)”（\(group.regionCounts.keys.sorted().joined(separator: "、"))）" }
                    let target = item.targetID.flatMap(anon.label(forTargetID:)) ?? item.targetName ?? "删除"
                    return "\(item.subject) → \(item.kind == .removeRule ? "删除" : target)"
                }.joined(separator: "；")
                reply = "\(proposal.status == .written ? "已写入草稿" : "已提出修改")：\(summary)"
            case .clarification(let question, _), .clarify(let question, _): reply = question
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
            case .understanding(let text):
                turn.understanding = text
            case .reasoning(let text):
                turn.reasoning = text
            case .retrying(let problem):
                turn.repairedFrom = problem
                turn.steps[0].detail = "第一次回答无法使用，已自动让 AI 修正"
            case .searching(let queries):
                turn.steps[0].detail = "正在联网搜索：\(queries.joined(separator: "；"))"
            case .searched(let records):
                turn.searches = (turn.searches ?? []) + records
                turn.steps[0].detail = "已联网搜索 \(turn.searches?.count ?? 0) 条，正在根据结果生成计划"
            case .lookedUp(let hints):
                turn.lookups = hints
                if turn.sentPayload != nil { turn.sentPayload?.lookups = hints.message }
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
            case let .clarification(question, options): turn.outcome = .clarify(question, options: options)
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

    /// Accepts or clears every item of the latest pending proposal (menu command).
    func setAllAccepted(_ accepted: Bool) {
        guard let id = latestProposalTurnID, let turn = current?.turns.first(where: { $0.id == id }),
              let proposal = turn.proposal, proposal.status == .pending else { return }
        let all = Set(proposal.items.map(\.id))
        let target = accepted ? all : []
        guard target != proposal.accepted else { return }
        rebuild(turnID: id, plan: proposal.plan, accepted: target)
    }

    var hasPendingProposal: Bool {
        guard let id = latestProposalTurnID else { return false }
        return current?.turns.first { $0.id == id }?.proposal?.status == .pending
    }

    func setAccepted(_ accepted: Bool, item: Int, turnID: UUID) {
        guard let turn = current?.turns.first(where: { $0.id == turnID }), var proposal = turn.proposal, proposal.status == .pending else { return }
        if accepted { proposal.accepted.insert(item) } else { proposal.accepted.remove(item) }
        rebuild(turnID: turnID, plan: proposal.plan, accepted: proposal.accepted)
    }

    /// Replaces a pending new group's name, type and members (chosen in the editor), then rebuilds
    /// and re-validates the candidate. Existing groups are still never modified.
    func editNewGroup(_ target: GroupEditTarget, name: String, type: String, members: [String]) {
        guard let draft, let turn = current?.turns.first(where: { $0.id == target.turnID }), let proposal = turn.proposal,
              proposal.status == .pending, target.itemID < proposal.plan.operations.count,
              case .group(let old) = proposal.plan.operations[target.itemID] else { return }
        let ids = members.compactMap { name in draft.target(named: name)?.id }
        var plan = proposal.plan
        plan.operations[target.itemID] = .group(EditPlan.NewGroup(id: old.id, name: name.trimmingCharacters(in: .whitespaces), type: type, regions: [], members: ids))
        rebuild(turnID: target.turnID, plan: plan, accepted: proposal.accepted)
    }

    /// Applies `plan` with `accepted` to the turn's base draft in the background; writing waits.
    private func rebuild(turnID: UUID, plan: EditPlan, accepted: Set<Int>) {
        guard let session = current, let draft, let turn = session.turns.first(where: { $0.id == turnID }), let proposal = turn.proposal else { return }
        mutateTurn(sessionID: session.id, turnID: turnID) { turn in
            turn.proposal?.accepted = accepted
            turn.proposal?.plan = plan
        }
        let engine = engine, items = proposal.items, sessionID = session.id, regions = regions
        let isLatest: @Sendable (Turn) -> Bool = { $0.proposal?.accepted == accepted && $0.proposal?.plan == plan }
        revalidating.insert(turnID)
        Task { [weak self] in
            defer { if let turn = self?.current?.turns.first(where: { $0.id == turnID }), isLatest(turn) { self?.revalidating.remove(turnID) } }
            do {
                let result = try await engine.reapply(plan: plan, accepted: accepted, draft: draft, regions: regions, previous: items)
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    guard isLatest(turn) else { return }
                    turn.proposal?.candidate = result.candidate
                    turn.proposal?.items = result.items
                    turn.proposal?.validation = result.validation
                }
            } catch {
                self?.mutateTurn(sessionID: sessionID, turnID: turnID) { turn in
                    guard isLatest(turn) else { return }
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

    /// Whether the inspector already shows this turn's changes, so a "查看差异" link would do nothing.
    func inspectorShowsChanges(of turnID: UUID) -> Bool {
        inspectorPresented && inspectorTab == .changes && diffScope == .turn && (inspectedTurnID ?? latestProposalTurnID) == turnID
    }

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
        let stats = LineDiff.stats(diff(session.originalText, session.draftText))
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
            try keyStore.save(trimmed, for: settings.provider.rawValue)
            keySaved = true
            sessionKey = nil
        } else {
            sessionKey = trimmed
        }
    }

    func forgetKey() {
        keyStore.delete(for: settings.provider.rawValue)
        keySaved = false
        sessionKey = nil
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "aiSettings") }
    }

    /// What the next AI request may use for search; nil when search is off.
    var searchConfig: SearchConfig? {
        guard searchSettings.enabled else { return nil }
        let provider = searchSettings.provider
        let key: String?
        if let service = provider.aiServiceKey {
            key = sessionKeys[service] ?? keyStore.read(for: service.rawValue)
        } else {
            key = provider.needsKey ? keyStore.read(for: provider.keyAccount) : nil
        }
        return SearchConfig(provider: provider, apiKey: key, baseURL: provider.needsURL ? searchSettings.searxngURL : nil)
    }

    /// The address snapshot runs use to show an AI failure.
    static let snapshotTestAddress = "https://127.0.0.1:9/v1"

    /// Switches service, keeping the address and model the user had for it last time.
    func selectProvider(_ provider: AIProvider) {
        guard provider != settings.provider else { return }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "aiSettings.\(settings.provider.rawValue)") }
        if let data = defaults.data(forKey: "aiSettings.\(provider.rawValue)"), let saved = try? JSONDecoder().decode(AISettings.self, from: data),
           saved.provider == provider {
            settings = saved
        } else {
            settings = AISettings(provider: provider)
        }
    }

    /// Fetches the current service's model list and keeps it in settings.
    func fetchModels() async throws -> Int {
        let current = settings
        let models = try await AIClient().listModels(settings: current, apiKey: apiKey)
        guard settings.provider == current.provider else { return 0 }
        settings.fetchedModels = models
        return models.count
    }

    // MARK: Persistence & feedback

    /// Debounced; JSON encoding and the file write happen on a serial background queue.
    private func scheduleSave(_ session: Session, immediately: Bool = false) {
        saveWork[session.id]?.cancel()
        let store = store, queue = saveQueue
        let work = DispatchWorkItem { queue.async { try? store.save(session) } }
        saveWork[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.4), execute: work)
    }

    func flush() {
        for work in saveWork.values { work.cancel() }
        let store = store, snapshot = sessions
        saveQueue.sync { for session in snapshot { try? store.save(session) } }
    }

    /// Cheap value that changes when the conversation needs to scroll (new turn, step, outcome).
    var conversationToken: String {
        guard let turns = current?.turns, let last = turns.last else { return "" }
        let outcome: String
        switch last.outcome {
        case .running: outcome = "running"
        case .proposal(let proposal): outcome = "proposal-\(proposal.status.rawValue)"
        default: outcome = "done"
        }
        return "\(turns.count)-\(last.id)-\(last.steps.map(\.state.rawValue).joined())-\(outcome)"
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
