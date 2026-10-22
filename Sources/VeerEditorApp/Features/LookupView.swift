import AppKit
import SwiftUI
import VeerCore

/// Lookup tools for finer routing: which rule sets contain a domain or IP, how a domain
/// resolves, and what an IP is. Rule-set and IP lookups run on this Mac.
struct LookupView: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                SegmentedControl(label: "工具", selection: $store.lookupTab,
                                 options: LookupTab.allCases.map { .init(value: $0, title: $0.title) })
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            Divider()
            Group {
                switch store.lookupTab {
                case .ruleSets: RuleSetLookupTab()
                case .dns: DNSLookupTab()
                case .ip: IPLookupTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Color.surface)
        .onAppear { store.refreshGeoStatus() }
    }
}

// MARK: - Shared pieces

/// Query field with the tab's one primary action.
private struct LookupField: View {
    let prompt: String
    @Binding var text: String
    var running = false
    let run: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(run)
            Button(action: run) {
                if running { ProgressView().controlSize(.small).frame(width: 36) } else { Text("查询").frame(minWidth: 36) }
            }
            .buttonStyle(.borderedProminent).tint(.veerAccent).controlSize(.large)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || running)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Whether the geodata is on this Mac, with the download action when it is not.
private struct GeoDataBanner: View {
    @Environment(EditorStore.self) private var store
    let needed: String

    var body: some View {
        switch (store.geoStatus, store.geoDownload) {
        case (_, .running(let file)):
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("正在下载并校验 \(file.rawValue)（\(file.approximateSize)）…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        case (let status?, let state) where !status.isComplete:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Label("需要先下载 MetaCubeX 地理数据", systemImage: "arrow.down.circle").font(.headline)
                Text("\(needed)用到 \(GeoDataFile.allCases.map { "\($0.rawValue)（\($0.approximateSize)）" }.joined(separator: "、"))，从 GitHub 的 MetaCubeX/meta-rules-dat 下载并校验 SHA-256。下载后查询在本机进行，不会把域名或 IP 发出去。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .failed(let message) = state {
                    StatusBadge(kind: .failure, text: message, compact: true).fixedSize(horizontal: false, vertical: true)
                }
                Button(state == .idle ? "下载地理数据" : "重试") { store.downloadGeoData() }
                    .buttonStyle(.borderedProminent).tint(.veerAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        case (let status?, let state):
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("MetaCubeX 地理数据\(status.updated.map { " · 更新于 \($0.formatted(.relative(presentation: .named)))" } ?? "") · 查询在本机进行")
                if case .failed(let message) = state { StatusBadge(kind: .failure, text: message, compact: true) }
                Spacer()
                Button("更新") { store.downloadGeoData() }.buttonStyle(.link).foregroundStyle(Color.veerAccent)
                    .help("重新下载最新的地理数据（\(GeoDataFile.allCases.map(\.approximateSize).joined(separator: " + "))）")
            }
            .font(.caption).foregroundStyle(.secondary)
        default:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One MetaCubeX rule set in a result: name, why it matched, whether the draft uses it, and the
/// action that routes it.
private struct RuleSetRow: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let kind: String
    let name: String
    var detail: String?
    var broad = false
    var geositeOnly = false
    let usedBy: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(name).font(Typography.code).textSelection(.enabled)
                    if broad { Tag(text: "宽泛").help("整个国家、GFW 列表或大类，不适合只为一个网站使用") }
                    if geositeOnly { Tag(text: "仅 GEOSITE 规则", tint: .statusWarning).help("只通过关键词或正则命中；规则集文件（.mrs）不含这类条目，用 RULE-SET 不会命中") }
                    if let usedBy { Tag(text: "已在配置中 → \(usedBy)", tint: .statusSuccess) }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            }
            Spacer(minLength: Spacing.sm)
            Button("分流…") {
                store.routeWithRuleSet(source: "metacubex-\(kind)", name: name)
                openWindow(id: "main")
            }
            .buttonStyle(.bordered).neutralControl()
            .disabled(!store.canEditFromLookup || geositeOnly)
            .help(geositeOnly ? "规则集文件不含命中这个域名的条目" : store.canEditFromLookup ? "选择出口，把 \(name) 规则集加入草稿" : "先在主窗口打开一个已确认出口的会话")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 44)
    }
}

/// Rows in a raised panel with dividers.
private struct RowsPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Divider().padding(.leading, Spacing.lg) }
                    subview
                }
            }
        }
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(Color.separatorLine.opacity(0.6)))
    }
}

/// A rule the user can copy or hand to the conversation.
private struct RuleSuggestionRow: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let rule: String
    let explanation: String
    /// Instruction for the composer, when the editor can write this kind of rule.
    var instruction: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(rule).font(Typography.code).textSelection(.enabled)
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rule, forType: .string)
                store.showToast("已复制 \(rule)")
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("复制规则").accessibilityLabel("复制 \(rule)")
            if let instruction {
                Button("写入对话") {
                    store.draftInstruction(instruction)
                    openWindow(id: "main")
                }
                .buttonStyle(.bordered).neutralControl()
                .disabled(!store.canEditFromLookup)
                .help(store.canEditFromLookup ? "在输入框里写好“\(instruction)”，再用 @ 选择出口" : "先在主窗口打开一个已确认出口的会话")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: 44)
    }
}

/// geoip sets, ASN and rule suggestions for one address.
private struct IPReportView: View {
    @Environment(EditorStore.self) private var store
    let report: IPReport

    var body: some View {
        let used = store.usedRuleSets()
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Text(report.address.description).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                Tag(text: report.address.isV4 ? "IPv4" : "IPv6")
                if report.address.isFakeIP { Tag(text: "Fake-IP", tint: .statusWarning) }
                else if report.isPrivate { Tag(text: "局域网地址") }
            }
            if report.address.isFakeIP {
                StatusBadge(kind: .warning, text: "198.18.0.0/15 是代理软件分配的 Fake-IP，不是网站的真实地址；请用 DNS 页选择 DoH 服务器查真实地址。", compact: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let asn = report.asn {
                Label(String("AS\(asn.number) · \(asn.organization)"), systemImage: "building.2").font(.callout)
                    .textSelection(.enabled)
            } else if !report.isPrivate {
                Label("ASN 数据库中没有这个地址", systemImage: "building.2").font(.callout).foregroundStyle(.secondary)
            }
            if !report.geoip.isEmpty {
                SectionTitle(text: "包含它的 geoip 规则集")
                RowsPanel {
                    ForEach(report.geoip, id: \.self) { name in
                        RuleSetRow(kind: "geoip", name: name, detail: GeoIPNames.describe(name), usedBy: used["geoip:\(name)"])
                    }
                }
            }
            if !report.isPrivate, !report.address.isFakeIP {
                SectionTitle(text: "也可以按 IP 写规则")
                RowsPanel {
                    if let asn = report.asn {
                        RuleSuggestionRow(rule: "IP-CIDR\(report.address.isV4 ? "" : "6"),\(asn.network)",
                                          explanation: "\(asn.organization) 的整个网段（\(asn.network)）。",
                                          instruction: "\(asn.network) 走 ")
                        RuleSuggestionRow(rule: "IP-ASN,\(asn.number)",
                                          explanation: "AS\(asn.number) 的所有地址，Mihomo 用同一个 GeoLite2-ASN 数据库判断。Veer 暂不能直接写入这类规则，可以复制后手动添加。")
                    }
                    RuleSuggestionRow(rule: "IP-CIDR\(report.address.isV4 ? "" : "6"),\(report.address.network(prefix: report.address.isV4 ? 32 : 128))",
                                      explanation: "只匹配这一个地址；网站换地址后就不再命中。",
                                      instruction: "\(report.address.network(prefix: report.address.isV4 ? 32 : 128)) 走 ")
                }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
}

/// Plain-language names for geoip sets that are not country codes.
enum GeoIPNames {
    static let lists: [String: String] = [
        "private": "局域网与保留地址", "cn": "中国大陆", "telegram": "Telegram", "google": "Google", "netflix": "Netflix",
        "facebook": "Meta / Facebook", "twitter": "X / Twitter", "cloudflare": "Cloudflare", "cloudfront": "Amazon CloudFront", "fastly": "Fastly",
    ]

    static func describe(_ name: String) -> String {
        if let known = lists[name] { return known }
        if name.count == 2, let country = Locale(identifier: "zh_CN").localizedString(forRegionCode: name.uppercased()) { return "国家或地区：\(country)" }
        return "IP 段列表"
    }
}

// MARK: - Rule sets

private struct RuleSetLookupTab: View {
    @Environment(EditorStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var running = false
    @State private var result: Result?

    enum Result {
        case domain(String, [GeoSiteHit])
        case address(IPReport)
        case message(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("哪些规则集包含它").font(.title3.weight(.semibold))
                    Text("输入域名或 IP，查找包含它的 MetaCubeX geosite / geoip 规则集，并直接用来分流。比按名称猜规则集更准确。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LookupField(prompt: "例如 www.netflix.com 或 1.1.1.1", text: $text, running: running, run: run)
                GeoDataBanner(needed: "规则集查询")
                results
            }
            .padding(Spacing.xl)
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: takeRequest)
        .onChange(of: store.lookupRequest) { takeRequest() }
    }

    @ViewBuilder private var results: some View {
        switch result {
        case .none:
            EmptyView()
        case .message(let message):
            StatusBadge(kind: .info, text: message).fixedSize(horizontal: false, vertical: true)
        case .address(let report):
            IPReportView(report: report)
        case let .domain(domain, hits) where hits.isEmpty:
            VStack(alignment: .leading, spacing: Spacing.md) {
                StatusBadge(kind: .neutral, text: "没有 MetaCubeX 规则集包含 \(domain)")
                RowsPanel {
                    RuleSuggestionRow(rule: "DOMAIN-SUFFIX,\(Self.siteDomain(domain))", explanation: "按域名直接写规则：\(Self.siteDomain(domain)) 及其子域名。",
                                      instruction: "\(Self.siteDomain(domain)) 走 ")
                }
            }
        case let .domain(domain, hits):
            let used = store.usedRuleSets()
            let specific = hits.filter { !$0.isBroad }, broad = hits.filter(\.isBroad)
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("\(hits.count) 个规则集包含 \(domain)").font(.headline)
                if !specific.isEmpty {
                    RowsPanel { ForEach(specific) { row($0, used: used) } }
                }
                if !broad.isEmpty {
                    SectionTitle(text: "宽泛分类")
                    RowsPanel { ForEach(broad) { row($0, used: used) } }
                }
                SectionTitle(text: "也可以按域名写规则")
                RowsPanel {
                    RuleSuggestionRow(rule: "DOMAIN-SUFFIX,\(Self.siteDomain(domain))", explanation: "只针对这个网站，不依赖规则集。",
                                      instruction: "\(Self.siteDomain(domain)) 走 ")
                }
            }
        }
    }

    private func row(_ hit: GeoSiteHit, used: [String: String]) -> some View {
        let detail = hit.matches.prefix(2).map { "\($0.kind.title) \($0.value)" + ($0.attributes.isEmpty ? "" : "（@\($0.attributes.joined(separator: " @"))）") }
            .joined(separator: "；")
        return RuleSetRow(kind: "geosite", name: hit.name, detail: "命中：\(detail)", broad: hit.isBroad,
                          geositeOnly: hit.geositeRuleOnly, usedBy: used["geosite:\(hit.name)"])
    }

    /// The site's own domain for a suffix rule: drops a leading `www.`.
    static func siteDomain(_ domain: String) -> String {
        domain.hasPrefix("www.") && domain.split(separator: ".").count > 2 ? String(domain.dropFirst(4)) : domain
    }

    private func takeRequest() {
        guard let request = store.lookupRequest, request.tab == .ruleSets else { return }
        store.lookupRequest = nil
        text = request.text
        run()
    }

    private func run() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            do {
                if let address = IPAddr(query) {
                    guard await store.geo.status().has(.geoip) else { result = .message("请先下载地理数据。"); return }
                    result = .address(try await store.geo.report(for: address))
                } else if let domain = GeoLookup.domain(in: query) {
                    let available = await RuleSetIndex.shared.geositeCatalog()
                    guard let hits = try await store.geo.ruleSets(for: domain, available: available) else {
                        result = .message("请先下载地理数据。")
                        return
                    }
                    result = .domain(domain, hits)
                } else {
                    result = .message("请输入域名（例如 www.netflix.com）或 IP 地址。")
                }
            } catch {
                result = .message((error as? EditorError)?.message ?? "查询失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - DNS

private struct DNSLookupTab: View {
    @Environment(EditorStore.self) private var store
    @State private var text = ""
    @State private var type = DNSRecordType.a
    @State private var serverID = "阿里 DoH"
    @State private var custom = ""
    @State private var running = false
    @State private var outcome: Outcome?

    enum Outcome {
        case result(DNSResult)
        case failure(String)
    }

    /// Presets, then the servers in the current config that can be asked from here.
    private var choices: [(id: String, title: String, server: DNSServer)] {
        var list = DNSServer.presets.map { (id: $0.title, title: $0.title, server: $0.server) }
        for raw in configured where DNSServer(mihomo: raw) != nil {
            list.append((id: "config:\(raw)", title: "配置：\(raw)", server: DNSServer(mihomo: raw)!))
        }
        return list
    }

    private var configured: [String] { store.draft.map { DNSServer.configured(in: $0.text) } ?? [] }

    private var server: DNSServer? {
        serverID == "custom" ? DNSServer(mihomo: custom) : choices.first { $0.id == serverID }?.server
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("DNS 查询").font(.title3.weight(.semibold))
                    Text("看一个域名解析到哪些地址、经过哪些 CNAME。查询只发给你选择的服务器。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LookupField(prompt: "例如 www.jal.co.jp", text: $text, running: running, run: run)
                Form {
                    Picker("服务器", selection: $serverID) {
                        Section("常用") {
                            ForEach(DNSServer.presets, id: \.title) { Text($0.title).tag($0.title) }
                        }
                        let fromConfig = choices.filter { $0.id.hasPrefix("config:") }
                        if !fromConfig.isEmpty {
                            Section("当前配置中的 DNS") {
                                ForEach(fromConfig, id: \.id) { Text($0.title).tag($0.id) }
                            }
                        }
                        Text("自定义…").tag("custom")
                    }
                    .neutralControl()
                    if serverID == "custom" {
                        TextField("地址", text: $custom, prompt: Text("https://…/dns-query、223.5.5.5 或 udp://host:53"))
                    }
                    Picker("记录类型", selection: $type) {
                        ForEach(DNSRecordType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.selectionNeutral)
                    let unsupported = configured.filter { DNSServer(mihomo: $0) == nil }
                    if !unsupported.isEmpty {
                        Text("配置中的 \(unsupported.prefix(3).joined(separator: "、"))\(unsupported.count > 3 ? " 等" : "") 暂不支持在这里查询（只支持 DoH 与 UDP）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .padding(.horizontal, -Spacing.xl)
                results
            }
            .padding(Spacing.xl)
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: takeRequest)
        .onChange(of: store.lookupRequest) { takeRequest() }
    }

    @ViewBuilder private var results: some View {
        switch outcome {
        case .none:
            EmptyView()
        case .failure(let message):
            StatusBadge(kind: .failure, text: message).fixedSize(horizontal: false, vertical: true)
        case .result(let result):
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    StatusBadge(kind: result.status == "NOERROR" ? (result.answers.isEmpty ? .neutral : .success) : .warning,
                                text: result.status == "NOERROR" && result.answers.isEmpty ? "没有 \(result.type.rawValue) 记录" : result.status)
                    Text(verbatim: "\(result.server.label) · \(Int(result.duration * 1000)) ms").font(.caption).foregroundStyle(.secondary)
                }
                if result.answers.contains(where: { $0.address?.isFakeIP == true }) {
                    StatusBadge(kind: .warning, text: "结果是 198.18.x.x 的 Fake-IP：本机的代理软件接管了这个 DNS 请求。要看真实地址，请选择 DoH 服务器。", compact: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !result.answers.isEmpty {
                    RowsPanel {
                        ForEach(result.answers) { answer in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                Tag(text: answer.type).frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(answer.data).font(Typography.code).textSelection(.enabled)
                                    Text(answer.name + (answer.ttl.map { " · TTL \($0) 秒" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Spacing.sm)
                                if let address = answer.address {
                                    Button("查询 IP") {
                                        store.lookupRequest = LookupRequest(tab: .ip, text: address.description)
                                        store.lookupTab = .ip
                                    }
                                    .buttonStyle(.bordered).neutralControl()
                                } else if answer.type == "CNAME" {
                                    Button("查规则集") {
                                        store.lookupRequest = LookupRequest(tab: .ruleSets, text: answer.data)
                                        store.lookupTab = .ruleSets
                                    }
                                    .buttonStyle(.bordered).neutralControl()
                                    .help("CDN 的域名也可能在规则集里")
                                }
                            }
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
    }

    private func takeRequest() {
        guard let request = store.lookupRequest, request.tab == .dns else { return }
        store.lookupRequest = nil
        text = request.text
        run()
    }

    private func run() {
        guard let server else { outcome = .failure("服务器地址无效：支持 https:// 开头的 DoH 地址、IP 或 udp://host:port。"); return }
        let query = text, type = type
        running = true
        Task {
            defer { running = false }
            do {
                outcome = .result(try await DNSResolver().lookup(query, type: type, server: server))
            } catch let error as EditorError {
                outcome = .failure(error.message)
            } catch {
                outcome = .failure("查询失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - IP

private struct IPLookupTab: View {
    @Environment(EditorStore.self) private var store
    @State private var text = ""
    @State private var running = false
    @State private var reports: [IPReport] = []
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("IP 查询").font(.title3.weight(.semibold))
                    Text("查看 IP 属于哪个国家或地区、哪个网络（ASN），以及可以用哪些规则分流。输入域名时先用阿里 DoH 解析，避开本机代理的 Fake-IP。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LookupField(prompt: "例如 1.1.1.1、2606:4700::1111 或 www.netflix.com", text: $text, running: running, run: run)
                GeoDataBanner(needed: "IP 查询")
                if let note { StatusBadge(kind: .info, text: note, compact: true).fixedSize(horizontal: false, vertical: true) }
                ForEach(reports) { report in
                    IPReportView(report: report)
                    if report.id != reports.last?.id { Divider() }
                }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: Metrics.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: takeRequest)
        .onChange(of: store.lookupRequest) { takeRequest() }
    }

    private func takeRequest() {
        guard let request = store.lookupRequest, request.tab == .ip else { return }
        store.lookupRequest = nil
        text = request.text
        run()
    }

    private func run() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        running = true
        Task {
            defer { running = false }
            note = nil
            do {
                guard await store.geo.status().isComplete else { reports = []; note = "请先下载地理数据。"; return }
                var addresses: [IPAddr] = []
                if let address = IPAddr(query) {
                    addresses = [address]
                } else if let domain = GeoLookup.domain(in: query) {
                    let resolver = DNSResolver(), server = DNSServer.presets[1].server
                    for type in [DNSRecordType.a, .aaaa] {
                        let result = try? await resolver.lookup(domain, type: type, server: server)
                        addresses += (result?.answers.compactMap(\.address) ?? []).filter { !addresses.contains($0) }
                    }
                    guard !addresses.isEmpty else { reports = []; note = "\(domain) 没有解析到地址。"; return }
                    note = "\(domain) 通过阿里 DoH 解析到 \(addresses.count) 个地址\(addresses.count > 6 ? "，只显示前 6 个" : "")。"
                } else {
                    reports = []
                    note = "请输入 IP 地址或域名。"
                    return
                }
                var found: [IPReport] = []
                for address in addresses.prefix(6) { found.append(try await store.geo.report(for: address)) }
                reports = found
            } catch {
                reports = []
                note = (error as? EditorError)?.message ?? "查询失败：\(error.localizedDescription)"
            }
        }
    }
}
