import SwiftUI
import VeerCore

/// Composer popover: parse mode, the service's models and the thinking-strength slider.
struct ModelPopover: View {
    @Environment(EditorStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        @Bindable var store = store
        let settings = store.settings
        VStack(alignment: .leading, spacing: Spacing.md) {
            Picker("解析方式", selection: $store.useAI) {
                Text("AI").tag(true)
                Text("本地解析").tag(false)
            }
            .pickerStyle(.segmented)
            .neutralSegments()
            .labelsHidden()
            if store.useAI && !store.aiConfigured {
                HStack {
                    StatusBadge(kind: .warning, text: "还没有 \(settings.provider.title) 的 API Key", compact: true)
                    Spacer()
                    Button("设置…", action: openSettings).buttonStyle(.link).foregroundStyle(Color.veerAccent)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("模型 · \(settings.provider.title)").font(.caption).foregroundStyle(.secondary)
                let models = settings.models(includingFetched: true)
                ScrollView {
                    VStack(spacing: Spacing.xxs) {
                        ForEach(models, id: \.self) { model in
                            ModelRow(model: model, selected: model == settings.model) {
                                store.settings.select(model: model)
                                store.useAI = true
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: models.count > 7 ? 220 : nil)
                .fixedSize(horizontal: false, vertical: models.count <= 7)
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Label("深度思考", systemImage: "brain").font(.callout)
                    Spacer()
                    Text(settings.thinkingStyle.adjustable ? settings.thinkingStyle.title(of: settings.effectiveLevel)
                         : settings.thinks ? "始终开启" : "不支持")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if settings.thinkingStyle.adjustable {
                    ThinkingSlider(style: settings.thinkingStyle,
                                   level: Binding(get: { store.settings.effectiveLevel }, set: { store.settings.thinkingLevel = $0 }))
                    Text("强度越高，理解复杂指令越好，但更慢、费用更高。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(settings.thinks ? "推理模型，总是先思考再回答。" : "此模型不能深度思考，可换用支持的模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(store.useAI ? 1 : 0.5)

            Divider()
            Button("AI 设置…", action: openSettings).buttonStyle(.link).foregroundStyle(Color.veerAccent)
        }
        .padding(Spacing.lg)
        .frame(width: 300)
    }
}

/// One selectable model in the popover list.
private struct ModelRow: View {
    let model: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Text(model).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Spacing.sm)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.veerAccent).fontWeight(.semibold) }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs + Spacing.xxs)
            .background(selected ? Color.veerAccent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
