import SwiftUI
import VeerCore

/// Composer pill for how much the conversation may do without asking, with a menu like Claude's
/// mode menu. 完整权限 is tinted, as Codex marks full access.
struct ExecutionModePicker: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let mode = store.executionMode
        let tint: Color? = mode == .full ? .statusWarning : nil
        Button { store.showingExecutionModePicker.toggle() } label: { Image(systemName: mode.symbol) }
        .buttonStyle(PillButtonStyle(tint: tint))
        .fixedSize()
        .help("执行模式：\(mode.title)。\(mode.detail)")
        .accessibilityLabel("执行模式：\(mode.title)")
        .popover(isPresented: $store.showingExecutionModePicker, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("执行模式").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.bottom, Spacing.xxs)
                ForEach(Array(ExecutionMode.allCases.enumerated()), id: \.element) { index, choice in
                    ChoiceRow(number: index + 1, symbol: choice.symbol, title: choice.title, detail: choice.detail,
                              selected: choice == mode, tint: choice == .full ? .statusWarning : nil) {
                        store.executionMode = choice
                        store.showingExecutionModePicker = false
                    }
                }
                Text("写入的都是草稿：随时可以撤销，原始文件不会改变。").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.xs)
            }
            .padding(Spacing.sm)
            .frame(width: 380)
        }
    }
}
