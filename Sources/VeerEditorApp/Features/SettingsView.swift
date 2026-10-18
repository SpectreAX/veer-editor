import SwiftUI
import VeerCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsPane().tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsPane().tabItem { Label("隐私", systemImage: "lock.shield") }
            ValidatorSettingsPane().tabItem { Label("校验", systemImage: "checkmark.seal") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

struct AISettingsPane: View {
    @Environment(EditorStore.self) private var store
    @State private var key = ""
    @State private var remember = true
    @State private var testState: TestState = .idle
    @State private var keyError: String?
    @State private var fetchState: TestState = .idle
    @State private var customModel = ""

    enum TestState: Equatable { case idle, running, passed, failed(String) }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("服务", selection: Binding(get: { store.settings.provider }, set: { provider in
                    store.selectProvider(provider)
                    testState = .idle
                    fetchState = .idle
                    key = ""
                })) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                TextField("地址", text: $store.settings.baseURL, prompt: Text(store.settings.provider.baseURL.isEmpty ? "https://…/v1" : store.settings.provider.baseURL))
                if store.settings.provider.needsKey { keyRow }
                LabeledContent("连接") {
                    HStack {
                        Button("测试连接") { test() }.disabled(testState == .running || !store.aiConfigured)
                        status(testState, passed: "可以连接，JSON 输出正常")
                    }
                }
            }
            Section {
                Picker("模型", selection: Binding(get: { store.settings.choice.id }, set: { id in
                    if let choice = store.settings.choices.first(where: { $0.id == id }) { store.settings.select(choice) }
                    testState = .idle
                })) {
                    ForEach(store.settings.choices) { choice in
                        Label(choice.title, systemImage: choice.thinking ? "brain" : "sparkles").tag(choice.id)
                    }
                }
                LabeledContent("其他模型") {
                    HStack {
                        TextField("其他模型", text: $customModel, prompt: Text("输入模型 ID"))
                            .labelsHidden()
                            .onSubmit(useCustomModel)
                        Button("使用", action: useCustomModel)
                            .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                LabeledContent("模型列表") {
                    HStack {
                        Button(store.settings.fetchedModels.isEmpty ? "从服务获取" : "重新获取") { fetch() }
                            .disabled(fetchState == .running || !store.aiConfigured)
                        status(fetchState, passed: "已获取 \(store.settings.fetchedModels.count) 个模型")
                    }
                }
                Text("标有“深度思考”的选项让模型先推理再回答，更擅长理解复杂指令，但更慢、费用更高。DeepSeek Reasoner、o4-mini、R1 等推理模型始终深度思考；Claude、Gemini 2.5 Flash、GPT-5、GLM 可在同一模型的普通与深度思考之间切换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("对话默认使用 AI 解析", isOn: $store.useAI)
                Text("AI 回答无法使用时，Veer 会把问题发回让它修正一次。测试连接和获取模型列表不包含任何配置。地址必须是 HTTPS，本机服务可以用 HTTP。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
    }

    private var keyRow: some View {
        @Bindable var store = store
        return LabeledContent("API Key") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if store.keySaved || store.sessionKey != nil {
                    HStack {
                        StatusBadge(kind: .success, text: store.keySaved ? "已保存到钥匙串" : "仅本次运行有效", compact: true)
                        Spacer()
                        Button("移除") { store.forgetKey(); testState = .idle }
                    }
                } else {
                    SecureField("粘贴 \(store.settings.provider.title) 的 API Key", text: $key)
                    Toggle("保存到钥匙串", isOn: $remember)
                    HStack {
                        Button("保存") {
                            do { try store.saveKey(key, remember: remember); key = ""; keyError = nil } catch { keyError = store.message(for: error) }
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let keyError { Text(keyError).foregroundStyle(Color.statusFailure).font(.caption) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func status(_ state: TestState, passed: String) -> some View {
        switch state {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .passed: StatusBadge(kind: .success, text: passed, compact: true)
        case .failed(let message): StatusBadge(kind: .failure, text: message, compact: true).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func useCustomModel() {
        let model = customModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        store.settings.select(store.settings.provider.choices(for: model)[0])
        customModel = ""
        testState = .idle
    }

    private func test() {
        testState = .running
        let settings = store.settings, key = store.apiKey
        Task {
            do {
                try await AIClient().testConnection(settings: settings, apiKey: key)
                testState = .passed
            } catch {
                testState = .failed(store.message(for: error))
            }
        }
    }

    private func fetch() {
        fetchState = .running
        Task {
            do {
                _ = try await store.fetchModels()
                fetchState = .passed
            } catch {
                fetchState = .failed(store.message(for: error))
            }
        }
    }
}

struct PrivacySettingsPane: View {
    @Environment(EditorStore.self) private var store
    @State private var confirming = false

    var body: some View {
        Form {
            Section("发送给 AI 的内容") {
                Label("匿名化的配置 YAML：策略组与节点改为“策略组N”“节点N”，只保留结构、策略组类型和声明的地区", systemImage: "checkmark")
                Label("现有规则的类型与匿名出口；具体域名和 IP 默认替换为占位符", systemImage: "checkmark")
                Label("你的指令，其中的出口名称会替换成匿名标签", systemImage: "checkmark")
                Label("本会话最近几轮的匿名摘要，用于理解追问", systemImage: "checkmark")
            }
            Section("从不发送") {
                Label("真实的节点、策略组和代理集名称", systemImage: "xmark")
                Label("节点地址、端口、密码、UUID、协议与传输参数", systemImage: "xmark")
                Label("订阅链接、规则集与 Provider 地址", systemImage: "xmark")
                Label("DNS、TUN、端口、控制器等其他配置", systemImage: "xmark")
            }
            Section {
                Toggle("发送现有规则中的具体域名和 IP", isOn: Binding(get: { store.shareRuleLiterals }, set: { store.shareRuleLiterals = $0 }))
                    .toggleStyle(.checkbox)
                Text("关闭时这些值显示为 <域名N>、<IPN>。打开后 AI 能看到你现有的分流目标，可能包含内网或个人常用域名。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("每一轮 AI 对话下方都有“查看发送给 AI 的内容”，可以核对实际发送的文字。你在指令里亲自输入的秘密无法被自动识别，请勿粘贴密钥或订阅链接。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("清除所有本地会话…", role: .destructive) { confirming = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除所有本地会话？", isPresented: $confirming) {
            Button("清除", role: .destructive) { store.deleteAllSessions() }
        } message: {
            Text("会删除本机保存的全部对话与草稿，原始配置文件不受影响。")
        }
    }
}

struct ValidatorSettingsPane: View {
    @Environment(EditorStore.self) private var store
    @State private var version: String?
    @State private var loaded = false

    var body: some View {
        @Bindable var store = store
        Form {
            LabeledContent("内置 Mihomo") {
                if !loaded { ProgressView().controlSize(.small) }
                else if let version { StatusBadge(kind: .success, text: "可用 · \(version)", compact: true) }
                else { StatusBadge(kind: .warning, text: "不可用：只进行结构检查", compact: true) }
            }
            Toggle("导出前默认进行内核校验", isOn: $store.validateBeforeExport).toggleStyle(.checkbox)
            Text("每次生成修改后，Veer 用内置 Mihomo 的 -t 配置测试检查候选配置。通过只代表配置能被解析，不代表网络可达或服务可解锁。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            let validator = store.engine
            version = await Task.detached { validator.validatorVersion }.value
            loaded = true
        }
    }
}

struct ExportSheet: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var validate = true
    @State private var exporting = false
    @State private var error: String?

    var body: some View {
        let stats = store.exportStats
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("导出完整配置副本").font(.headline)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("相对原始配置：+\(stats.added) 行 / −\(stats.removed) 行" + (stats.providers > 0 ? "，新增 \(stats.providers) 个规则集" : ""))
                Text("除 rules 与新增的 rule-providers 外，其余内容与原文逐字节一致。").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("导出前进行内核校验", isOn: $validate).toggleStyle(.checkbox)
            Label("不会覆盖导入的原始文件，也不会应用到正在运行的代理。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
            if let error { StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…", action: chooseLocation).keyboardShortcut(.defaultAction).disabled(exporting)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .onAppear { validate = store.validateBeforeExport }
    }

    private func chooseLocation() {
        guard let session = store.current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml]
        let base = (session.title as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base)-veer.yaml"
        panel.message = "导出完整配置副本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        Task {
            do {
                try await store.export(to: url, validate: validate)
                dismiss()
            } catch {
                self.error = store.message(for: error)
            }
            exporting = false
        }
    }
}
