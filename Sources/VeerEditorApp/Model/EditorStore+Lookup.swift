import AppKit
import Foundation
import VeerCore

enum LookupTab: String, CaseIterable, Identifiable {
    case ruleSets, dns, ip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ruleSets: "规则集"
        case .dns: "DNS"
        case .ip: "IP"
        }
    }
}

struct LookupRequest: Equatable {
    var id = UUID()
    let tab: LookupTab
    let text: String
}

enum GeoDownloadState: Equatable {
    case idle
    case running(GeoDataFile)
    case failed(String)
}

struct RuleSetPrefill: Equatable {
    let source: String
    let name: String
}

extension EditorStore {
    /// Whether results can be turned into edits: a session is open and its exits are confirmed.
    var canEditFromLookup: Bool { !showingStart && current?.exitsConfirmed == true && !isRunning }

    func refreshGeoStatus() {
        Task { geoStatus = await geo.status() }
    }

    func downloadGeoData() {
        if case .running = geoDownload { return }
        geoDownload = .running(.geosite)
        Task {
            do {
                try await geo.download { file in Task { @MainActor in self.geoDownload = .running(file) } }
                geoDownload = .idle
            } catch {
                geoDownload = .failed((error as? EditorError)?.message ?? "下载失败：\(error.localizedDescription)")
            }
            geoStatus = await geo.status()
        }
    }

    /// MetaCubeX rule sets the draft already uses, by kind ("geosite" / "geoip") and name, with
    /// the exit they route to.
    func usedRuleSets() -> [String: String] {
        guard let draft else { return [:] }
        var used: [String: String] = [:]
        for rule in draft.rules {
            guard let parts = RuleParts.parse(rule), let payload = parts.payload else { continue }
            switch parts.type.uppercased() {
            case "GEOSITE": used["geosite:\(payload.lowercased())"] = parts.target
            case "GEOIP": used["geoip:\(payload.lowercased())"] = parts.target
            case "RULE-SET":
                guard let set = draft.providers.first(where: { $0.key == payload })?.url.flatMap(MetaCubeXSet.init(url:)) else { continue }
                used["\(set.kind):\(set.name)"] = parts.target
            default: continue
            }
        }
        return used
    }

    /// Opens the add-rule-set sheet in the main window with this set filled in.
    func routeWithRuleSet(source: String, name: String) {
        ruleSetPrefill = RuleSetPrefill(source: source, name: name)
        showingRuleSetSheet = true
    }

    /// Puts an instruction into the composer for the user to finish (usually the exit).
    func draftInstruction(_ text: String) {
        composerText = text
        composerFocusToken += 1
    }
}
