import AppKit
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

/// Selectable suggestion pill. Enabled pills carry a faint accent edge and react to the pointer,
/// so they read as clickable; disabled ones (for example in older turns) fade out.
struct Chip: View {
    let text: String
    var symbol: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(isEnabled ? Color.veerAccent : Color.secondary) }
                Text(text).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(hovering && isEnabled ? Color.veerAccent.opacity(0.12) : Color.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(isEnabled ? Color.veerAccent.opacity(0.35) : Color.separatorLine))
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// On / off pill for a composer option. Off it matches the neutral mode pill beside it; on it takes
/// an accent wash, edge and text, so the state reads from more than color alone (also announced as
/// selected).
struct ToggleChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    /// Icon only, for narrow rows; the title stays as the accessibility label.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.adaptive(compact))
                .font(.callout)
                .foregroundStyle(isOn && isEnabled ? Color.veerAccent : isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, Spacing.sm + Spacing.xxs)
                .padding(.vertical, Spacing.xs)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(isOn && isEnabled ? Color.veerAccent.opacity(0.4) : .clear))
                .opacity(isEnabled ? 1 : 0.6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: isOn)
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var background: Color {
        guard isEnabled else { return Color.primary.opacity(0.06) }
        if isOn { return Color.veerAccent.opacity(hovering ? 0.2 : 0.14) }
        return Color.primary.opacity(hovering ? 0.1 : 0.06)
    }
}

private struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { Label(configuration) }
    }
}

extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(_ iconOnly: Bool) -> AdaptiveLabelStyle { AdaptiveLabelStyle(iconOnly: iconOnly) }
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

extension View {
    /// The native, uncolored look for selection controls and secondary buttons. The accent is
    /// kept for the one primary action of a view, so it stays easy to find.
    func neutralControl() -> some View { tint(nil) }
}

/// The standard SwiftUI segmented picker with the selected segment in neutral gray
/// (`Color.selectionNeutral`), so the accent stays on primary actions (impeccable review,
/// 2026-10-19).
struct SegmentedControl<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
    }

    let label: String
    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Group {
                    if let symbol = option.symbol {
                        Image(systemName: symbol).accessibilityLabel(option.title).help(option.title)
                    } else {
                        Text(option.title)
                    }
                }
                .tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(Color.selectionNeutral)
    }
}

/// A menu choice like Claude's mode menu: icon, title, what it does, a check when current, and
/// its number key (pressed while the menu is open).
struct ChoiceRow: View {
    let number: Int
    let symbol: String
    let title: String
    let detail: String
    let selected: Bool
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: symbol).frame(width: Spacing.lg).foregroundStyle(tint ?? .secondary)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.body).foregroundStyle(tint ?? .primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.veerAccent).fontWeight(.semibold) }
                Text(verbatim: "\(number)").font(.callout).foregroundStyle(.tertiary).frame(minWidth: Spacing.md)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
