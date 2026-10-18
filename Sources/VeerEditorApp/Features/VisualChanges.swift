import SwiftUI
import VeerCore

/// Changes as people think about them: group cards, rule rows and rule sets, instead of YAML lines.
struct VisualChangesView: View {
    @Environment(EditorStore.self) private var store
    let diff: ConfigDiff
    /// Pending new groups in the inspected proposal that can still be edited, by name.
    let editable: [String: GroupEditTarget]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                summary
                ForEach(diff.groupsAdded) { group in
                    GroupCard(name: group.name, type: group.type, members: group.members.map(\.name), badge: "新增",
                              analysis: diff.after, highlighted: [], removed: [],
                              edit: editable[group.name].map { target in { store.editingGroup = target } })
                }
                ForEach(diff.groupsChanged) { change in
                    let members = diff.after?.groups.first { $0.name == change.name }?.members.map(\.name) ?? []
                    GroupCard(name: change.name, type: change.newType, members: members, badge: "已修改",
                              analysis: diff.after, highlighted: Set(change.added), removed: change.removed, edit: nil)
                }
                ForEach(diff.groupsRemoved, id: \.self) { name in
                    Label("删除策略组 \(name)", systemImage: "minus.circle").foregroundStyle(Color.statusFailure).font(.callout)
                }
                if !diff.rules.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("规则").font(.headline)
                        ForEach(diff.rules) { RuleChangeRow(change: $0) }
                    }
                }
                if !diff.providersAdded.isEmpty || !diff.providersRemoved.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("规则集").font(.headline)
                        FlowLayout(spacing: Spacing.xs + Spacing.xxs) {
                            ForEach(diff.providersAdded, id: \.self) { key in
                                Label(key, systemImage: "plus").font(.caption).padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs + 1)
                                    .background(Color.diffAdded, in: Capsule())
                            }
                            ForEach(diff.providersRemoved, id: \.self) { key in
                                Label(key, systemImage: "minus").font(.caption).padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs + 1)
                                    .background(Color.diffRemoved, in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }

    private var summary: some View {
        let addedRules = diff.rules.filter { $0.kind == .added }.count, removedRules = diff.rules.count - addedRules
        var parts: [String] = []
        if !diff.groupsAdded.isEmpty { parts.append("新增 \(diff.groupsAdded.count) 个策略组") }
        if !diff.groupsChanged.isEmpty { parts.append("修改 \(diff.groupsChanged.count) 个策略组") }
        if addedRules > 0 { parts.append("新增 \(addedRules) 条规则") }
        if removedRules > 0 { parts.append("删除 \(removedRules) 条规则") }
        if !diff.providersAdded.isEmpty { parts.append("新增 \(diff.providersAdded.count) 个规则集") }
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }
}

/// Dashboard-style group card: header with type and member count, then member tiles.
struct GroupCard: View {
    let name: String
    let type: String
    let members: [String]
    let badge: String?
    let analysis: ProfileAnalysis?
    let highlighted: Set<String>
    let removed: [String]
    let edit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Color.veerAccent)
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(ProfileAnalysis.mihomoType(type).uppercased()) · \(members.count)").font(.caption).foregroundStyle(.secondary)
                if let badge { Tag(text: badge, tint: .veerAccent) }
                Spacer(minLength: 0)
                if let edit {
                    Button(action: edit) { Label("编辑", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.borderless).font(.callout).help("修改名称、类型和成员")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: Spacing.sm)], spacing: Spacing.sm) {
                ForEach(members, id: \.self) { member in
                    MemberTile(name: member, detail: detail(for: member), count: count(for: member), highlighted: highlighted.contains(member))
                }
            }
            if !removed.isEmpty {
                Text("移除：\(removed.joined(separator: "、"))").font(.caption).foregroundStyle(Color.statusFailure)
            }
        }
        .padding(Spacing.md)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.7)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("策略组 \(name)，\(members.count) 个出口")
    }

    private func detail(for member: String) -> String {
        if member == "DIRECT" { return "direct" }
        if member == "REJECT" || member == "REJECT-DROP" { return "reject" }
        if let group = analysis?.groups.first(where: { $0.name == member }) { return ProfileAnalysis.mihomoType(group.type) }
        if let type = analysis?.proxyTypes[member] { return type.lowercased() }
        return "未知"
    }

    private func count(for member: String) -> Int? {
        analysis?.groups.first { $0.name == member }?.members.count
    }
}

struct MemberTile: View {
    let name: String
    let detail: String
    let count: Int?
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(name)
            HStack(spacing: Spacing.xs) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(Color.veerAccent)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, 1)
                        .background(Color.veerAccent.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(Spacing.sm + Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .strokeBorder(highlighted ? Color.veerAccent : Color.separatorLine, lineWidth: highlighted ? 1.5 : 1))
        .accessibilityElement(children: .combine)
    }
}

struct RuleChangeRow: View {
    let change: ConfigDiff.RuleChange

    var body: some View {
        let added = change.kind == .added
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: added ? "plus.circle.fill" : "minus.circle.fill")
                .foregroundStyle(added ? Color.veerAccent : Color.statusFailure)
            Text("#\(change.position)").font(Typography.codeSmall).foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
            Tag(text: change.type)
            if !change.payload.isEmpty {
                Text(change.payload).font(Typography.codeSmall).lineLimit(1).truncationMode(.middle)
                    .strikethrough(!added, color: Color.statusFailure.opacity(0.6))
            }
            Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
            Text(change.target).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(added ? "新增" : "删除")规则 \(change.rule)")
    }
}
