import Foundation

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case same, added, removed }
    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String
}

/// A display block: changed lines, or a run of unchanged lines that the UI may fold.
public enum DiffBlock: Sendable, Hashable, Identifiable {
    case lines([DiffLine])
    case folded(id: Int, count: Int, lines: [DiffLine])

    public var id: Int {
        switch self {
        case .lines(let lines): lines.first?.id ?? -1
        case .folded(let id, _, _): -1_000_000 - id
        }
    }
}

public enum LineDiff {
    /// Myers diff over lines. O((N+M)·D); falls back to a full replace beyond `maxEdits`.
    public static func diff(_ old: String, _ new: String, maxEdits: Int = 4000) -> [DiffLine] {
        let a = split(old), b = split(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        let ops = patience(midA[...], midB[...], maxEdits: maxEdits)

        var lines: [DiffLine] = []
        var oldLine = 0, newLine = 0
        func emit(_ kind: DiffLine.Kind, _ text: String) {
            lines.append(DiffLine(id: lines.count, kind: kind,
                                  oldNumber: kind == .added ? nil : oldLine + 1,
                                  newNumber: kind == .removed ? nil : newLine + 1, text: text))
            if kind != .added { oldLine += 1 }
            if kind != .removed { newLine += 1 }
        }
        for line in a[0..<prefix] { emit(.same, line) }
        var i = 0, j = 0
        for op in ops {
            switch op {
            case .keep: emit(.same, midA[i]); i += 1; j += 1
            case .remove: emit(.removed, midA[i]); i += 1
            case .insert: emit(.added, midB[j]); j += 1
            }
        }
        for line in a[(a.count - suffix)...] { emit(.same, line) }
        return lines
    }

    /// Groups lines, folding unchanged runs longer than `2 * context`.
    public static func blocks(_ lines: [DiffLine], context: Int = 3) -> [DiffBlock] {
        var blocks: [DiffBlock] = []
        var index = 0
        while index < lines.count {
            if lines[index].kind != .same {
                var end = index
                while end < lines.count, lines[end].kind != .same { end += 1 }
                blocks.append(.lines(Array(lines[index..<end])))
                index = end
                continue
            }
            var end = index
            while end < lines.count, lines[end].kind == .same { end += 1 }
            let run = Array(lines[index..<end])
            let leading = index == 0 ? 0 : context
            let trailing = end == lines.count ? 0 : context
            if run.count > leading + trailing + 1 {
                if leading > 0 { blocks.append(.lines(Array(run.prefix(leading)))) }
                let hidden = Array(run.dropFirst(leading).dropLast(trailing))
                blocks.append(.folded(id: hidden.first?.id ?? index, count: hidden.count, lines: hidden))
                if trailing > 0 { blocks.append(.lines(Array(run.suffix(trailing)))) }
            } else {
                blocks.append(.lines(run))
            }
            index = end
        }
        return blocks
    }

    public static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    enum Op { case keep, remove, insert }

    /// Patience diff: anchor on lines unique to both sides (in LCS order), recurse between
    /// anchors, and use Myers only for the gaps. Keeps repeated YAML lines like `type: http`
    /// from being matched across unrelated blocks.
    static func patience(_ a: ArraySlice<String>, _ b: ArraySlice<String>, maxEdits: Int) -> [Op] {
        if a.isEmpty { return Array(repeating: .insert, count: b.count) }
        if b.isEmpty { return Array(repeating: .remove, count: a.count) }
        var countA: [String: Int] = [:], countB: [String: Int] = [:], indexB: [String: Int] = [:]
        for line in a { countA[line, default: 0] += 1 }
        for (i, line) in zip(b.indices, b) { countB[line, default: 0] += 1; indexB[line] = i }
        let pairs = zip(a.indices, a).compactMap { i, line in
            countA[line] == 1 && countB[line] == 1 ? (i, indexB[line]!) : nil
        }
        let anchors = longestIncreasing(pairs)
        guard !anchors.isEmpty else {
            return myers(Array(a), Array(b), maxEdits: maxEdits) ?? (Array(repeating: .remove, count: a.count) + Array(repeating: .insert, count: b.count))
        }
        var ops: [Op] = []
        var lastA = a.startIndex, lastB = b.startIndex
        for (i, j) in anchors {
            ops += patience(a[lastA..<i], b[lastB..<j], maxEdits: maxEdits)
            ops.append(.keep)
            lastA = i + 1; lastB = j + 1
        }
        ops += patience(a[lastA...], b[lastB...], maxEdits: maxEdits)
        return ops
    }

    /// Longest chain of pairs increasing in both coordinates (patience sorting).
    static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = [], previous = Array(repeating: -1, count: pairs.count)
        for (k, pair) in pairs.enumerated() {
            var low = 0, high = tails.count
            while low < high { let mid = (low + high) / 2; if pairs[tails[mid]].1 < pair.1 { low = mid + 1 } else { high = mid } }
            if low > 0 { previous[k] = tails[low - 1] }
            if low == tails.count { tails.append(k) } else { tails[low] = k }
        }
        var result: [(Int, Int)] = []
        var k = tails.last ?? -1
        while k >= 0 { result.append(pairs[k]); k = previous[k] }
        return result.reversed()
    }

    static func myers(_ a: [String], _ b: [String], maxEdits: Int) -> [Op]? {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .remove, count: n) }
        let maxD = min(n + m, maxEdits)
        let offset = maxD + 1
        var v = Array(repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { return backtrack(trace: trace, a: a, b: b, offset: offset, d: d) }
            }
        }
        return nil
    }

    static func backtrack(trace: [[Int]], a: [String], b: [String], offset: Int, d: Int) -> [Op] {
        var ops: [Op] = []
        var x = a.count, y = b.count
        for depth in stride(from: d, to: 0, by: -1) {
            let v = trace[depth]
            let k = x - y
            let prevK = (k == -depth || (k != depth && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let prevX = v[offset + prevK], prevY = prevX - prevK
            while x > prevX, y > prevY { ops.append(.keep); x -= 1; y -= 1 }
            ops.append(x == prevX ? .insert : .remove)
            x = prevX; y = prevY
        }
        while x > 0, y > 0 { ops.append(.keep); x -= 1; y -= 1 }
        return ops.reversed()
    }
}
