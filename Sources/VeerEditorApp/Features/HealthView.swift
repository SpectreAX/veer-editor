import SwiftUI
import VeerCore

/// 配置体检: problems the draft certainly has, each with a fix that goes through review when one is safe.
struct HealthTab: View {
    @Environment(EditorStore.self) private var store

    var body: some View {
        let findings = store.healthFindings
        let fixable = findings.filter { !$0.fix.isEmpty }
        if store.draft == nil {
            StateView(symbol: "stethoscope", title: "没有可体检的草稿", message: "导入配置后，这里会列出能从配置本身确认的问题。")
        } else if findings.isEmpty {
            StateView(symbol: "checkmark.seal", title: "没有发现确定的问题",
                      message: "已检查规则顺序、重复规则、引用、空策略组、未使用的规则集和 MATCH 兜底。DNS 和节点可用性要到运行时才知道，体检不做推测。")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("发现 \(findings.count) 个问题").font(.headline)
                        Text(counts(findings)).font(.caption).foregroundStyle(.secondary)
                        Text("只列出能从配置本身确认的问题。修复会先生成修改，经 Mihomo 校验后由你确认写入草稿。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if findings.contains(where: { $0.severity == .error }) {
                            StatusBadge(kind: .warning, text: "有问题会让 Mihomo 无法加载配置。先处理它们，其他修复才能通过校验。", compact: true)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if fixable.count > 1 {
                        Button { store.fixHealth(fixable) } label: { Label("修复全部可修复项（\(fixable.count)）", systemImage: "wrench.and.screwdriver") }
                            .buttonStyle(.bordered).neutralControl()
                            .disabled(store.isRunning)
                            .help("把所有可以安全修复的问题放进一组修改，逐项确认后再写入")
                    }
                    ForEach(findings) { FindingCard(finding: $0) }
                }
                .padding(Spacing.lg)
            }
        }
    }

    private func counts(_ findings: [HealthFinding]) -> String {
        let parts: [(HealthFinding.Severity, String)] = [(.error, "会导致无法加载"), (.warning, "规则问题"), (.notice, "可清理")]
        return parts.compactMap { severity, label in
            let count = findings.filter { $0.severity == severity }.count
            return count == 0 ? nil : "\(label) \(count) 个"
        }.joined(separator: " · ")
    }
}

struct FindingCard: View {
    @Environment(EditorStore.self) private var store
    let finding: HealthFinding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            StatusBadge(kind: kind, text: finding.title)
            if finding.ruleIndex != nil || tag != nil {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    if let index = finding.ruleIndex {
                        Text("第 \(index + 1) 条").font(.caption).foregroundStyle(.secondary).fixedSize()
                        Text(finding.subject).font(Typography.codeSmall).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            .help(finding.subject)
                    } else if let tag {
                        Tag(text: tag)
                        Text(finding.subject).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(finding.subject)
                    }
                }
            }
            Text(finding.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let hint = finding.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let fixTitle = finding.fixTitle, !finding.fix.isEmpty {
                Button(fixTitle) { store.fixHealth([finding]) }
                    .buttonStyle(.bordered).controlSize(.small).neutralControl()
                    .disabled(store.isRunning)
                    .help("生成删除修改，确认后才写入草稿")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Spacing.md)
        .accessibilityElement(children: .contain)
    }

    private var kind: StatusKind {
        switch finding.severity {
        case .error: .failure
        case .warning: .warning
        case .notice: .info
        }
    }

    private var tag: String? {
        switch finding.kind {
        case .missingMember, .emptyGroup: "策略组"
        case .unusedProvider: "规则集"
        default: nil
        }
    }
}
