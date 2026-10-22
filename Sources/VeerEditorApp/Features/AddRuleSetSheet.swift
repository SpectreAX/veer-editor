import SwiftUI
import VeerCore

/// Adds an online rule set (rule-provider + RULE-SET rule) without AI. The result appears in the
/// conversation as a normal review card.
struct AddRuleSetSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var source = "metacubex-geosite"
    @State private var name = ""
    @State private var url = ""
    @State private var behavior = "domain"
    @State private var targetID = ""
    /// Set while a prefilled source is applied, so its name is not cleared.
    @State private var keepName = false

    static let sources: [(id: String, title: String, names: [String])] = [
        ("metacubex-geosite", "MetaCubeX geosite（域名，推荐）", SystemPrompt.geositeNames),
        ("metacubex-geoip", "MetaCubeX geoip（IP 段）", SystemPrompt.geoipNames),
        ("acl4ssr", "ACL4SSR（混合规则）", SystemPrompt.acl4ssrNames),
        ("blackmatrix7", "blackmatrix7（混合规则，分类最细）", SystemPrompt.blackmatrix7Names),
    ]

    private var reference: RuleSetReference? {
        if mode == 0 {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .catalog(source: source, name: trimmed)
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .url(trimmed, behavior: behavior)
    }

    private var preview: Result<RuleSetCatalog.Spec, EditorError>? {
        guard let reference else { return nil }
        do { return .success(try RuleSetCatalog.spec(for: reference)) } catch let error as EditorError { return .failure(error) } catch { return nil }
    }

    private var suggestions: [String] {
        let names = Self.sources.first { $0.id == source }?.names ?? []
        let query = name.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? names : names.filter { $0.lowercased().contains(query) && $0.lowercased() != query }
    }

    private var visibleSuggestions: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return Array(suggestions.prefix(8)) }
        return Array(suggestions.filter { $0.lowercased().contains(typed) && $0.lowercased() != typed }.prefix(12))
    }

    var body: some View {
        let targets = store.draft?.targets ?? []
        let regions = store.regions
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("添加在线规则集").font(.title3.weight(.semibold))
                Text("把一个在线规则集里的网站交给你选的出口。Veer 会先确认地址存在、用 Mihomo 校验，再交给你审阅后写入草稿。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SegmentedControl(label: "方式", selection: $mode,
                             options: [.init(value: 0, title: "从常用仓库选择"), .init(value: 1, title: "粘贴规则集地址")])
            .fixedSize()

            Form {
                if mode == 0 {
                    Picker("来源", selection: $source) {
                        ForEach(Self.sources, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .neutralControl()
                    TextField("名称", text: $name, prompt: Text("例如 youtube"))
                    if !visibleSuggestions.isEmpty {
                        LabeledContent("常用名称") {
                            FlowLayout(spacing: Spacing.xs) {
                                // A short list until the user types; then the names that match.
                                ForEach(visibleSuggestions, id: \.self) { suggestion in
                                    Button(suggestion) { name = suggestion }.buttonStyle(.bordered).controlSize(.small).neutralControl()
                                }
                            }
                        }
                    }
                } else {
                    TextField("地址", text: $url, prompt: Text("https://raw.githubusercontent.com/…"))
                    Picker("类型", selection: $behavior) {
                        Text("域名（domain）").tag("domain")
                        Text("IP 段（ipcidr）").tag("ipcidr")
                        Text("混合规则（classical）").tag("classical")
                    }
                    .neutralControl()
                    Text("geosite / geoip 路径与 .list 文件的类型会自动判断；.yaml 文件按这里的选择。").font(.caption).foregroundStyle(.secondary)
                }
                Picker("出口", selection: $targetID) {
                    Text("请选择").tag("")
                    ForEach(targets) { target in
                        Text(exitLabel(target, region: regions[target.name])).tag(target.id)
                    }
                }
                .neutralControl()
                LabeledContent("预览") {
                    switch preview {
                    case .none:
                        Text("填写后显示地址").foregroundStyle(.tertiary)
                    case .success(let spec):
                        VStack(alignment: .trailing, spacing: Spacing.xxs) {
                            Text(spec.url).font(Typography.codeSmall).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            Text("\(spec.behavior) · \(spec.format) · 规则集名 \(spec.key)").font(.caption).foregroundStyle(.secondary)
                        }
                    case .failure(let error):
                        StatusBadge(kind: .failure, text: error.message, compact: true).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("列表里的名称都已确认可用；其他名称也可以填写，地址不存在时会提示你。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).neutralControl()
                Button("生成修改") {
                    guard let reference else { return }
                    store.addRuleSet(reference, targetID: targetID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(reference == nil || targetID.isEmpty || store.isRunning || (try? preview?.get()) == nil)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 620)
        .onChange(of: source) {
            if keepName { keepName = false } else { name = "" }
        }
        .onAppear {
            guard let prefill = store.ruleSetPrefill else { return }
            store.ruleSetPrefill = nil
            mode = 0
            keepName = prefill.source != source
            source = prefill.source
            name = prefill.name
        }
    }

    private func exitLabel(_ target: Target, region: Region?) -> String {
        switch target.kind {
        case .builtin: target.name == "DIRECT" ? "DIRECT（直连）" : "REJECT（拦截）"
        default: "\(target.name) · \(target.kind.label)\(region.map { $0 == .unknown ? "" : " · \($0.displayName)" } ?? "")"
        }
    }
}
