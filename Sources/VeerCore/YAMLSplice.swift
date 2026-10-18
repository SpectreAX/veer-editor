import Foundation
import Yams

/// Line-level editing of top-level values. Only the edited value's source lines change; every
/// other byte (comments, quoting, unknown keys) is preserved.
struct SourceLines {
    var lines: [String]
    let newline: String
    let endsWithNewline: Bool

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        endsWithNewline = text.hasSuffix("\n")
        var parts = text.components(separatedBy: "\n")
        if endsWithNewline { parts.removeLast() }
        lines = parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    var text: String {
        lines.joined(separator: newline) + (endsWithNewline || lines.isEmpty ? newline : "")
    }

    static func isTrivia(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
}

struct ValueRegion {
    /// Line of the `key:` itself.
    let keyLine: Int
    /// First line after the value, before trailing blank/comment lines.
    let end: Int
}

enum YAMLSplice {
    static func region(for key: String, in document: ConfigDocument, lines: SourceLines) -> ValueRegion? {
        guard let index = document.topLevelKeys.firstIndex(where: { $0.key == key }) else { return nil }
        let start = document.topLevelKeys[index].line
        var end = index + 1 < document.topLevelKeys.count ? document.topLevelKeys[index + 1].line : lines.lines.count
        while end > start + 1 && SourceLines.isTrivia(lines.lines[end - 1]) { end -= 1 }
        return ValueRegion(keyLine: start, end: end)
    }

    /// The part of the key line after `key:` with any trailing comment removed.
    static func inlineValue(_ line: String) -> String {
        guard let colon = line.range(of: ":") else { return "" }
        var rest = String(line[colon.upperBound...])
        if let comment = rest.range(of: " #") { rest = String(rest[..<comment.lowerBound]) }
        else if rest.trimmingCharacters(in: .whitespaces).hasPrefix("#") { rest = "" }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Renders one scalar so it parses back to exactly `value`.
    static func scalar(_ value: String) -> String {
        let plainUnsafe = value.isEmpty
            || value.first.map { "-?:,[]{}#&*!|>'\"%@` ".contains($0) } == true
            || value.last == " "
            || value.contains(": ") || value.contains(" #") || value.hasSuffix(":")
            || ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"].contains(value.lowercased())
            || Double(value) != nil
        if !plainUnsafe, let parsed = try? Yams.load(yaml: "- " + value) as? [String], parsed == [value] { return value }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    // MARK: rules

    struct RuleItem {
        var leading: [String]
        var line: String
    }

    /// Splits a block sequence into single-line items. Returns nil when the layout is not a
    /// simple block sequence (flow style, multi-line items); callers then re-render the value.
    static func ruleItems(region: ValueRegion, lines: SourceLines, expected: [String]) -> (items: [RuleItem], indent: String)? {
        guard inlineValue(lines.lines[region.keyLine]).isEmpty else { return nil }
        var items: [RuleItem] = []
        var pending: [String] = []
        var indent: Int?
        for line in lines.lines[(region.keyLine + 1)..<region.end] {
            if SourceLines.isTrivia(line) { pending.append(line); continue }
            let level = SourceLines.indentation(line)
            let body = line.dropFirst(level)
            guard body == "-" || body.hasPrefix("- ") else { return nil }
            if indent == nil { indent = level }
            guard level == indent else { return nil }
            items.append(RuleItem(leading: pending, line: line))
            pending = []
        }
        guard items.count == expected.count else { return nil }
        for (item, value) in zip(items, expected) {
            let text = String(item.line.dropFirst(indent ?? 0))
            guard let parsed = try? Yams.load(yaml: text) as? [Any], parsed.count == 1, (parsed[0] as? String) == value else { return nil }
        }
        return (items, String(repeating: " ", count: indent ?? 2))
    }

    /// Replaces the `rules` value. `final` lists each resulting rule and, if it is an
    /// untouched original, the index of its source item so its lines are kept verbatim.
    static func replaceRules(in lines: inout SourceLines, document: ConfigDocument, final: [(rule: String, original: Int?, inheritComments: Int?)]) {
        let region = region(for: "rules", in: document, lines: lines)
        let layout = region.flatMap { ruleItems(region: $0, lines: lines, expected: document.rules) }
        let indent = layout?.indent ?? "  "
        var body: [String] = []
        for entry in final {
            if let original = entry.original, let layout {
                body.append(contentsOf: layout.items[original].leading)
                body.append(layout.items[original].line)
            } else {
                if let source = entry.inheritComments, let layout { body.append(contentsOf: layout.items[source].leading) }
                body.append("\(indent)- \(scalar(entry.rule))")
            }
        }
        let replacement = final.isEmpty ? ["rules: []"] : ["rules:"] + body
        if let region {
            let keyComment = trailingComment(lines.lines[region.keyLine])
            var head = replacement
            if let keyComment, !final.isEmpty { head[0] += " " + keyComment }
            lines.lines.replaceSubrange(region.keyLine..<region.end, with: head)
        } else {
            lines.lines.append(contentsOf: replacement)
        }
    }

    static func trailingComment(_ line: String) -> String? {
        guard inlineValue(line).isEmpty, let hash = line.range(of: "#") else { return nil }
        return String(line[hash.lowerBound...])
    }

    // MARK: rule-providers

    static func renderProvider(key: String, fields: [(String, String)], indent: String, step: String) -> [String] {
        var out = ["\(indent)\(scalar(key)):"]
        for (field, value) in fields {
            out.append("\(indent)\(step)\(field): \(field == "interval" ? value : scalar(value))")
        }
        return out
    }

    /// Appends new providers to `rule-providers`, creating the key when needed.
    static func addProviders(in lines: inout SourceLines, document: ConfigDocument, additions: [(key: String, fields: [(String, String)])]) throws {
        guard !additions.isEmpty else { return }
        if let region = region(for: "rule-providers", in: document, lines: lines) {
            let inline = inlineValue(lines.lines[region.keyLine])
            let bodyLines = lines.lines[(region.keyLine + 1)..<region.end].filter { !SourceLines.isTrivia($0) }
            if inline.isEmpty, let first = bodyLines.first {
                let childIndent = String(repeating: " ", count: SourceLines.indentation(first))
                let grandchild = bodyLines.dropFirst().map(SourceLines.indentation).first { $0 > childIndent.count }
                let step = String(repeating: " ", count: max(2, (grandchild ?? childIndent.count + 2) - childIndent.count))
                let rendered = additions.flatMap { renderProvider(key: $0.key, fields: $0.fields, indent: childIndent, step: step) }
                lines.lines.insert(contentsOf: rendered, at: region.end)
            } else if inline.isEmpty || inline == "{}" || inline == "null" || inline == "~" {
                let rendered = additions.flatMap { renderProvider(key: $0.key, fields: $0.fields, indent: "  ", step: "  ") }
                lines.lines.replaceSubrange(region.keyLine..<region.end, with: ["rule-providers:"] + rendered)
            } else {
                throw EditorError("rule-providers 使用了单行（flow）格式，当前版本无法安全添加规则集。请改为多行格式后重试。")
            }
        } else {
            let rendered = ["rule-providers:"] + additions.flatMap { renderProvider(key: $0.key, fields: $0.fields, indent: "  ", step: "  ") }
            if let rules = document.topLevelKeys.first(where: { $0.key == "rules" }) {
                lines.lines.insert(contentsOf: rendered, at: rules.line)
            } else {
                lines.lines.append(contentsOf: rendered)
            }
        }
    }

    // MARK: proxy-groups

    /// Renders new groups as block sequence items (via the YAML serializer), indented to `indent`.
    static func renderGroups(_ groups: [(name: String, type: String, members: [String])], indent: String) throws -> [String] {
        let items: [Node] = groups.map { group in
            var pairs: [(Node, Node)] = [
                (Node(stringLiteral: "name"), .scalar(.init(group.name, Tag(.str), .any))),
                (Node(stringLiteral: "type"), .scalar(.init(group.type, Tag(.str), .any))),
            ]
            if group.type == "url-test" || group.type == "fallback" {
                // Explicit health check rather than relying on kernel defaults.
                pairs.append((Node(stringLiteral: "url"), .scalar(.init("https://www.gstatic.com/generate_204", Tag(.str), .any))))
                pairs.append((Node(stringLiteral: "interval"), .scalar(.init("300", Tag(.int), .plain))))
            }
            pairs.append((Node(stringLiteral: "proxies"), .sequence(.init(group.members.map { .scalar(.init($0, Tag(.str), .any)) }, Tag(.seq), .block))))
            return .mapping(.init(pairs, Tag(.map), .block))
        }
        let yaml = ConfigImporter.readableUnicode(try Yams.serialize(node: .sequence(.init(items, Tag(.seq), .block)), indent: 2, width: -1, allowUnicode: true))
        return yaml.split(separator: "\n", omittingEmptySubsequences: true).map { indent + $0 }
    }

    /// Appends groups to the end of `proxy-groups`, creating the key when needed.
    static func addGroups(in lines: inout SourceLines, document: ConfigDocument, additions: [(name: String, type: String, members: [String])]) throws {
        guard !additions.isEmpty else { return }
        if let region = region(for: "proxy-groups", in: document, lines: lines) {
            let inline = inlineValue(lines.lines[region.keyLine])
            let body = lines.lines[(region.keyLine + 1)..<region.end].filter { !SourceLines.isTrivia($0) }
            if inline.isEmpty, let first = body.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                let indent = String(repeating: " ", count: SourceLines.indentation(first))
                lines.lines.insert(contentsOf: try renderGroups(additions, indent: indent), at: region.end)
            } else if (inline.isEmpty && body.isEmpty) || ["[]", "null", "~"].contains(inline) {
                lines.lines.replaceSubrange(region.keyLine..<region.end, with: ["proxy-groups:"] + (try renderGroups(additions, indent: "  ")))
            } else {
                throw EditorError("proxy-groups 使用了单行（flow）格式，当前版本无法安全新建策略组。请改为多行格式后重试。")
            }
        } else {
            let rendered = ["proxy-groups:"] + (try renderGroups(additions, indent: "  "))
            if let rules = document.topLevelKeys.first(where: { $0.key == "rules" }) {
                lines.lines.insert(contentsOf: rendered, at: rules.line)
            } else {
                lines.lines.append(contentsOf: rendered)
            }
        }
    }
}
