import Foundation

/// One imported configuration with its conversation and draft history.
public struct Session: Codable, Identifiable, Sendable, Equatable {
    public enum Source: Codable, Sendable, Equatable {
        case file(name: String, path: String)
        case subscription(host: String)
        case pasted
        case sample

        public var label: String {
            switch self {
            case .file: "本地文件"
            case .subscription(let host): "订阅 · \(host)"
            case .pasted: "粘贴"
            case .sample: "示例配置"
            }
        }
    }

    public let id: UUID
    public var title: String
    public var source: Source
    public let createdAt: Date
    public var updatedAt: Date
    /// The imported text. Never modified.
    public let originalText: String
    public var draftText: String
    /// Draft text at the last successful export; nil means never exported.
    public var exportedText: String?
    public var undoStack: [String]
    public var redoStack: [String]
    /// User corrections of inferred regions, keyed by exit name.
    public var regionOverrides: [String: Region]
    public var exitsConfirmed: Bool
    public var turns: [Turn]
    /// Set when the import was converted (Base64 / share links / node list) rather than used as-is.
    public var importNote: String?
    /// Traffic and expiry from the subscription response, if it sent any.
    public var subscriptionUsage: SubscriptionUsage?

    public init(title: String, source: Source, text: String, now: Date = .now) {
        id = UUID()
        self.title = title
        self.source = source
        createdAt = now
        updatedAt = now
        originalText = text
        draftText = text
        exportedText = nil
        undoStack = []
        redoStack = []
        regionOverrides = [:]
        exitsConfirmed = false
        turns = []
    }

    /// The draft differs from what was last exported (or from the original if never exported).
    public var hasUnexportedChanges: Bool { draftText != (exportedText ?? originalText) }

    public func regions(for targets: [Target]) -> [String: Region] {
        var result: [String: Region] = [:]
        for target in targets where target.kind != .builtin {
            result[target.name] = regionOverrides[target.name] ?? Region.infer(from: target.name)
        }
        return result
    }
}

/// One conversation entry.
public struct Turn: Codable, Identifiable, Sendable, Equatable {
    public enum Mode: Codable, Sendable, Equatable {
        case ai(model: String)
        case local
        public var label: String {
            switch self {
            case .ai(let model): "AI · \(model)"
            case .local: "本地解析"
            }
        }
    }

    public struct Step: Codable, Sendable, Equatable, Identifiable {
        public enum State: String, Codable, Sendable { case waiting, running, done, failed, cancelled }
        public let id: Int
        public let title: String
        public var state: State
        public var detail: String?

        public init(id: Int, title: String, state: State, detail: String? = nil) {
            self.id = id
            self.title = title
            self.state = state
            self.detail = detail
        }
    }

    public enum ProposalStatus: String, Codable, Sendable { case pending, written, undone, discarded, stale }

    public struct Proposal: Codable, Sendable, Equatable {
        public var plan: EditPlan
        public var items: [ChangeItem]
        public var accepted: Set<Int>
        /// Draft the plan was generated against; a different current draft makes it stale.
        public var baseDraft: String
        public var candidate: String
        public var validation: ValidationResult
        public var status: ProposalStatus
        /// Draft before and after writing, for per-turn diffs.
        public var writtenFrom: String?
        public var writtenTo: String?

        public init(plan: EditPlan, items: [ChangeItem], accepted: Set<Int>, baseDraft: String, candidate: String,
                    validation: ValidationResult, status: ProposalStatus) {
            self.plan = plan
            self.items = items
            self.accepted = accepted
            self.baseDraft = baseDraft
            self.candidate = candidate
            self.validation = validation
            self.status = status
        }
    }

    public enum Outcome: Codable, Sendable, Equatable {
        case running
        case proposal(Proposal)
        case noChange(String)
        /// Legacy form (sessions saved before 2026-10-18).
        case clarification(String, suggestions: [String])
        case clarify(String, options: [ClarifyOption])
        case outOfScope(String)
        case failure(message: String, opensSettings: Bool, canUseLocal: Bool)
        case cancelled
        case note(String)
    }

    public let id: UUID
    public let prompt: String
    public let createdAt: Date
    public let mode: Mode
    public var steps: [Step]
    public var outcome: Outcome
    public var sentPayload: AIRequestPayload?
    public var duration: TimeInterval?
    /// The model's one-line reading of the instruction (and its assumptions).
    public var understanding: String?
    /// Reasoning returned by a reasoning model when deep thinking was on.
    public var reasoning: String?
    /// Set when the first AI answer was unusable and Veer asked again.
    public var repairedFrom: String?
    /// Searches the model asked for, with what they found (also sent to the model).
    public var searches: [SearchRecord]?
    /// Local lookups of the instruction's domains and IPs.
    public var lookups: LookupHints?
    /// Domains the model had Veer test against the draft's rules.
    public var checks: [CheckRecord]?

    public init(prompt: String, mode: Mode, steps: [Step], outcome: Outcome = .running, now: Date = .now) {
        id = UUID()
        self.prompt = prompt
        createdAt = now
        self.mode = mode
        self.steps = steps
        self.outcome = outcome
    }

    public var proposal: Proposal? {
        get { if case .proposal(let proposal) = outcome { proposal } else { nil } }
        set { if let newValue { outcome = .proposal(newValue) } }
    }

    public var isNote: Bool { if case .note = outcome { true } else { false } }
}

extension Session {
    /// The draft a turn's AI request was made from. Drafts only change by writing, undoing or
    /// redoing, so it is one of the texts the session already keeps.
    public func sourceDraft(for payload: AIRequestPayload, regions: (ConfigDocument) -> [String: Region]) -> String? {
        var candidates = [draftText, originalText] + undoStack.reversed() + redoStack
        for turn in turns.reversed() {
            if let proposal = turn.proposal {
                candidates += [proposal.baseDraft, proposal.writtenFrom, proposal.writtenTo].compactMap { $0 }
            }
        }
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert(AIRequestPayload.digest($0)).inserted }
        if let digest = payload.sourceDigest {
            return unique.first { AIRequestPayload.digest($0) == digest }
        }
        // Payloads saved before 2026-10-19 have no digest: find the draft that produces the same YAML.
        guard let config = payload.config else { return nil }
        return unique.first { text in
            guard let document = try? ConfigDocument.parse(text) else { return false }
            let shared = !config.contains("已替换为 <域名N>")
            return AnonymizedConfig.make(document: document, regions: regions(document), shareRuleLiterals: shared).yaml == config
        }
    }
}
