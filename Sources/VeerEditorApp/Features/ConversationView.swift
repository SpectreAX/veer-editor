import SwiftUI
import VeerCore

struct ConversationView: View {
    @Environment(EditorStore.self) private var store
    @State private var followsBottom = true

    static let examples = ["Netflix 走日本，ChatGPT 走美国", "YouTube 走香港", "example.com 直连", "屏蔽广告"]

    var body: some View {
        let turns = store.current?.turns ?? []
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                    if turns.isEmpty { emptyState }
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
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: BottomTracking.self) { geometry in
                BottomTracking(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                               containerHeight: geometry.containerSize.height,
                               atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40)
            } action: { old, new in
                if new.atBottom {
                    followsBottom = true
                } else if new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight {
                    // Content grew (a step finished, a result arrived) or the window was resized:
                    // keep the newest turn in view if we were following it.
                    if followsBottom || old.atBottom {
                        followsBottom = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                } else if new.offset < old.offset - 1 {
                    // Moved up with the same content: the user is reading older turns. An animated
                    // scroll toward the bottom only ever moves down, so it never lands here.
                    followsBottom = false
                }
            }
            .onChange(of: store.conversationToken) {
                if followsBottom { withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: turns.count) { old, new in
                // A new turn is always something the user just asked for: show it.
                guard new > old else { return }
                followsBottom = true
                withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.selectedID) { followsBottom = true; proxy.scrollTo("bottom", anchor: .bottom) }
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
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var atBottom: Bool
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
