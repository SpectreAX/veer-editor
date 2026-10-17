import SwiftUI
import VeerCore

/// 4-point spacing grid. Views use these instead of literal values.
nonisolated enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

nonisolated enum Radius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 16
}

nonisolated enum Metrics {
    static let readingWidth: CGFloat = 760
    static let sidebarWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 360
    static let minWindow = CGSize(width: 960, height: 640)
    static let defaultWindow = CGSize(width: 1320, height: 860)
    static let compactBreakpoint: CGFloat = 1100
}

nonisolated enum Motion {
    static let quick = Animation.easeOut(duration: 0.15)
    static let standard = Animation.easeInOut(duration: 0.22)
}

extension Color {
    /// Veer green: small-area emphasis only (primary actions, selection, written state).
    static let veerAccent = Color(nsColor: NSColor(name: "VeerAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.80, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.62, blue: 0.33, alpha: 1)
    })
    /// User message bubble; deeper than the accent in dark mode so white text stays readable.
    static let userBubble = Color(nsColor: NSColor(name: "VeerBubble") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.10, green: 0.47, blue: 0.27, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.62, blue: 0.33, alpha: 1)
    })
    static let statusSuccess = Color.veerAccent
    static let statusWarning = Color(nsColor: .systemOrange)
    static let statusFailure = Color(nsColor: .systemRed)
    static let statusInfo = Color(nsColor: .systemBlue)

    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceRaised = Color(nsColor: .controlBackgroundColor)
    static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
    static let separatorLine = Color(nsColor: .separatorColor)
    static let codeBackground = Color(nsColor: .textBackgroundColor)
    static let diffAdded = Color.veerAccent.opacity(0.13)
    static let diffRemoved = Color(nsColor: .systemRed).opacity(0.11)
}

nonisolated enum Typography {
    static let code = Font.system(.callout, design: .monospaced)
    static let codeSmall = Font.system(.caption, design: .monospaced)
}

/// Semantic status, always rendered as icon + text.
enum StatusKind {
    case success, warning, failure, info, neutral

    var color: Color {
        switch self {
        case .success: .statusSuccess
        case .warning: .statusWarning
        case .failure: .statusFailure
        case .info: .statusInfo
        case .neutral: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    init(_ validation: ValidationResult.Status) {
        switch validation {
        case .passed: self = .success
        case .unavailable: self = .warning
        case .failed: self = .failure
        }
    }

    init(_ verification: RuleSetVerification) {
        switch verification {
        case .verified, .reused: self = .success
        case .unverified: self = .warning
        case .missing: self = .failure
        }
    }
}

extension RuleSetVerification {
    var label: String {
        switch self {
        case .verified: "地址已验证"
        case .unverified: "地址未验证（网络不可达）"
        case .missing: "地址不存在"
        case .reused: "复用已有规则集"
        }
    }
}

extension Target.Kind {
    var label: String {
        switch self {
        case .group: "策略组"
        case .node: "节点"
        case .builtin: "内置"
        }
    }
}
