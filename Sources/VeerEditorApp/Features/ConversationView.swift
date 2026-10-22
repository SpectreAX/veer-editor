import SwiftUI
import VeerCore

struct ConversationView: View {
    @Environment(EditorStore.self) private var store
    @State private var followsBottom = true

    static let examples = ["Netflix 走日本，ChatGPT 走美国", "YouTube 走香港", "example.com 直连", "屏蔽广告"]

    var body: some View {
        let allTurns = store.current?.turns ?? []
        let turns = allTurns.suffix(store.visibleTurnCount)
        let hidden = allTurns.count - turns.count
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    if turns.isEmpty { emptyState }
                    if hidden > 0, let first = turns.first?.id {
                        Button {
                            followsBottom = false
                            store.olderTurnPages += 1
                            // Keep the turn that was at the top in place instead of jumping to the oldest.
                            DispatchQueue.main.async { proxy.scrollTo(first, anchor: .top) }
                        } label: {
                            Label("显示更早的 \(min(EditorStore.turnPage, hidden)) 轮对话（还有 \(hidden) 轮）", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(Color.veerAccent)
                        .frame(maxWidth: .infinity)
                        .help("较早的对话不会自动显示，以便快速切换会话")
                    }
                    ForEach(turns) { turn in
                        TurnView(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.lg)
                .frame(maxWidth: Metrics.readingWidth)
                .frame(maxWidth: .infinity)
            }
            // A scroll view per session, opening at the newest turn. Reusing one kept the previous
            // session's scroll position, which can lie past the end of a shorter session's content
            // and left the conversation blank.
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: BottomTracking.self) { geometry in
                BottomTracking(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height)
            } action: { _, _ in
                // Content grew (a step finished, a result arrived), a lazy turn was measured, or the
                // window was resized: stay on the newest turn if we were following it. Layout never
                // decides that the user left the bottom; only their own scrolling does (below).
                if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onScrollPhaseChange { old, new, context in
                // The user finished scrolling (trackpad, wheel, scroll bar): follow the newest turn
                // again only if they ended at the bottom. Programmatic scrolls animate and are ignored.
                guard new == .idle, [.interacting, .decelerating, .tracking].contains(old) else { return }
                let geometry = context.geometry
                followsBottom = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                    || geometry.contentSize.height <= geometry.containerSize.height + 1
            }
            // After the geometry tracking, so a new session's scroll view is not compared with the
            // previous one's position.
            .id(store.selectedID)
            .onChange(of: store.conversationToken) {
                if followsBottom { withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: allTurns.count) { old, new in
                // A new turn is always something the user just asked for: show it.
                guard new > old else { return }
                followsBottom = true
                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selectedID) { followsBottom = true }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView()
                    .frame(maxWidth: Metrics.readingWidth)
                    // Floats just above the composer without taking layout space: if it changed the
                    // inset, its own appearance would move the view off the bottom and keep it shown.
                    .overlay(alignment: .top) {
                        if !followsBottom && !turns.isEmpty {
                            Button {
                                followsBottom = true
                                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
                            } label: {
                                Label("回到最新", systemImage: "arrow.down")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .neutralControl()
                            .help("滚动到最新一轮")
                            .fixedSize()
                            .offset(y: -(Spacing.xxl + Spacing.xs))
                            .transition(.opacity)
                        }
                    }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .padding(.top, Spacing.sm)
                .background {
                    LinearGradient(stops: [.init(color: Color.surface.opacity(0), location: 0), .init(color: Color.surface, location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
            }
        }
        .background(Color.surface)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("想怎么分流？").font(.title2.weight(.semibold))
                Text("用自然语言描述，例如某个服务走哪个出口。Veer 会生成修改，等你确认后才写入草稿；原始文件不会被改动。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: Spacing.sm) {
                ForEach(Self.examples, id: \.self) { example in
                    Chip(text: example, symbol: "text.bubble") { store.send(example) }
                }
            }
            if !store.effectiveUseAI {
                StatusBadge(kind: .info, text: "当前使用本地解析：支持常见服务、域名、地区与 @ 出口。需要更灵活的说法时，可在设置中配置 AI。", compact: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Spacing.xxl)
    }
}

private struct BottomTracking: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
