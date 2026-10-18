import SwiftUI
import VeerCore

/// Edits a new group from a pending review card: name, type and members (add, remove, reorder).
struct GroupEditorSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: GroupEditTarget
    @State private var name = ""
    @State private var type = "select"
    @State private var members: [String] = []
    @State private var search = ""
    @State private var loaded = false

    private var group: ChangeItem.GroupInfo? {
        store.current?.turns.first { $0.id == target.turnID }?.proposal?.items.first { $0.id == target.itemID }?.group
    }

    private var candidates: [Target] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (store.draft?.targets ?? []).filter { target in
            !members.contains(target.name) && (query.isEmpty || target.name.lowercased().contains(query))
        }
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "名称不能为空" }
        if trimmed.contains(",") || trimmed.count > 64 { return "名称不能包含逗号，最多 64 个字符" }
        if store.draft?.targets.contains(where: { $0.name == trimmed }) == true { return "已有同名的策略组或节点，保存后会自动加序号" }
        return nil
    }

    var body: some View {
        let regions = store.regions
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("编辑新策略组").font(.title3.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(Color.statusWarning) }
                Picker("类型", selection: $type) {
                    Text("select（手动选择）").tag("select")
                    Text("url-test（自动选延迟最低）").tag("url-test")
                    Text("fallback（按顺序故障转移）").tag("fallback")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 118)

            HStack(alignment: .top, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("成员（\(members.count)）· 拖动排序").font(.headline)
                    List {
                        ForEach(members, id: \.self) { member in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                ExitLabel(name: member, region: regions[member])
                                Spacer()
                                Button { members.removeAll { $0 == member } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("移除").accessibilityLabel("移除 \(member)")
                            }
                        }
                        .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("添加").font(.headline)
                    TextField("搜索出口", text: $search).textFieldStyle(.roundedBorder)
                    List(candidates) { target in
                        Button { members.append(target.name) } label: {
                            HStack {
                                ExitLabel(name: target.name, region: target.kind == .builtin ? nil : regions[target.name], kind: target.kind)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Color.veerAccent)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 300)

            HStack {
                Text("只修改这个新策略组；已有策略组不会改变。保存后会重新生成并校验。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.editNewGroup(target, name: name, type: type, members: members)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(members.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains(","))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 760, height: 640)
        .onAppear {
            guard !loaded, let group else { return }
            loaded = true
            name = group.name
            type = group.type
            members = group.members
        }
    }
}
