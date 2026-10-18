import SwiftUI
import VeerCore

/// Icon + text status label. Color is never the only cue.
struct StatusBadge: View {
    let kind: StatusKind
    let text: String
    var compact = false

    var body: some View {
        Label {
            Text(text).foregroundStyle(compact ? Color.secondary : Color.primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(compact ? .caption : .callout)
        .accessibilityElement(children: .combine)
    }
}

/// Small rounded tag, e.g. "策略组", "新增".
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs + Spacing.xxs)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Selectable suggestion pill.
struct Chip: View {
    let text: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(text).lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.separatorLine))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Centered empty / error / informational state with an optional action.
struct StateView: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 320)
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Uppercase-free section header used in the inspector and settings.
struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Exit name with its region and kind, used in lists and completions.
struct ExitLabel: View {
    let name: String
    let region: Region?
    var kind: Target.Kind?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(name).lineLimit(1).truncationMode(.middle).help(name)
            if let region { Text(region == .unknown ? "未指定地区" : region.displayName).font(.caption).foregroundStyle(.secondary) }
            if let kind { Tag(text: kind.label) }
        }
    }
}

/// Primary glass action. Uses native Liquid Glass; the system falls back to an opaque
/// treatment when Reduce Transparency is on.
struct PrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(.veerAccent)
            .controlSize(.large)
    }
}

extension View {
    func primaryAction() -> some View { modifier(PrimaryActionStyle()) }

    /// Solid content panel: no glass on content.
    func panel(padding: CGFloat = Spacing.lg) -> some View {
        self.padding(padding)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.6)))
    }
}

struct ToastView: View {
    let toast: Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.veerAccent)
            Text(toast.message).font(.callout)
            if toast.undoable {
                Button("撤销", action: undo).buttonStyle(.borderless).foregroundStyle(Color.veerAccent)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + Spacing.xxs)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}


/// Thinking strength as a stepped slider (one stop per level the model supports), with the
/// level names under their stops. Click a name to jump to it.
struct ThinkingSlider: View {
    let style: ThinkingStyle
    @Binding var level: ThinkingLevel

    var body: some View {
        let levels = style.levels
        let index = levels.firstIndex(of: style.resolve(level)) ?? 0
        VStack(spacing: Spacing.xxs) {
            Slider(value: Binding(get: { Double(index) }, set: { level = levels[min(max(Int($0.rounded()), 0), levels.count - 1)] }),
                   in: 0...Double(max(levels.count - 1, 1)), step: 1)
                .labelsHidden()
                .tint(.veerAccent)
            GeometryReader { geometry in
                // The knob's centre travels between the track ends, inset by about its radius.
                let inset = Spacing.sm + Spacing.xxs
                let track = geometry.size.width - inset * 2
                ForEach(Array(levels.enumerated()), id: \.element) { offset, item in
                    let label = Text(style.title(of: item))
                        .font(.caption)
                        .fontWeight(offset == index ? .semibold : .regular)
                        .foregroundStyle(offset == index ? Color.primary : Color.secondary)
                        .fixedSize()
                        .onTapGesture { level = item }
                    if offset == 0 {
                        label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    } else if offset == levels.count - 1 {
                        label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    } else {
                        label.position(x: inset + track * CGFloat(offset) / CGFloat(levels.count - 1), y: geometry.size.height / 2)
                    }
                }
            }
            .frame(height: Spacing.lg)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("深度思考强度")
        .accessibilityValue(style.title(of: levels[index]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index + 1 < levels.count { level = levels[index + 1] }
            case .decrement: if index > 0 { level = levels[index - 1] }
            @unknown default: break
            }
        }
    }
}
