import CryptoKit
import Foundation

// Local lookups in MetaCubeX's geodata (https://github.com/MetaCubeX/meta-rules-dat): which
// geosite / geoip rule sets contain a domain or IP, and an IP's ASN. The files are downloaded
// on request and read on this Mac; queries never leave it.

// MARK: - Protobuf

/// Just enough protobuf to walk geosite.dat / geoip.dat (v2ray routercommon messages).
struct ProtoReader {
    let bytes: UnsafeRawBufferPointer
    var position: Int
    let end: Int

    init(_ bytes: UnsafeRawBufferPointer, from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        position = start
        self.end = end ?? bytes.count
    }

    var atEnd: Bool { position >= end }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while position < end {
            let byte = bytes[position]
            position += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw EditorError("地理数据文件已损坏（varint）。")
    }

    /// Field number, wire type.
    mutating func tag() throws -> (Int, Int) {
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    /// Bounds of a length-delimited field.
    mutating func lengthDelimited() throws -> Range<Int> {
        let length = Int(try varint())
        guard length >= 0, position + length <= end else { throw EditorError("地理数据文件已损坏（长度）。") }
        defer { position += length }
        return position..<(position + length)
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: position += 8
        case 2: _ = try lengthDelimited()
        case 5: position += 4
        default: throw EditorError("地理数据文件已损坏（类型 \(wireType)）。")
        }
        guard position <= end else { throw EditorError("地理数据文件已损坏。") }
    }
}

// MARK: - geosite

/// How a geosite entry matches, as in v2ray's Domain.Type.
public enum GeoSiteMatchKind: Int, Sendable, Codable, Hashable {
    case keyword = 0, regex = 1, suffix = 2, full = 3

    public var title: String {
        switch self {
        case .keyword: "关键词"
        case .regex: "正则"
        case .suffix: "域名及子域名"
        case .full: "完整域名"
        }
    }

    /// Rule-set files (.mrs / domain yaml) only carry full and suffix entries; keyword and regex
    /// entries apply to GEOSITE rules alone.
    public var inRuleSetFiles: Bool { self == .suffix || self == .full }
}

/// One geosite entry that matches a domain.
public struct GeoSiteMatch: Sendable, Hashable {
    public let category: String
    public let attributes: [String]
    public let kind: GeoSiteMatchKind
    public let value: String
}

/// A geosite rule set (as named in meta-rules-dat, e.g. `google`, `google@cn`, `airchina@!cn`)
/// that contains the domain, and the entries that put it there.
public struct GeoSiteHit: Sendable, Hashable, Identifiable {
    public let name: String
    public let matches: [GeoSiteMatch]
    public var id: String { name }

    /// The domain only matches through keyword / regex entries, which rule-set files leave out.
    public var geositeRuleOnly: Bool { !matches.contains { $0.kind.inRuleSetFiles } }

    /// Catch-all sets (whole countries, the GFW list, TLDs, categories): too wide for one site.
    public var isBroad: Bool { Self.isBroad(name) }

    public static func isBroad(_ name: String) -> Bool {
        let base = name.split(separator: "@").first.map(String.init) ?? name
        return ["category-", "geolocation-", "tld-"].contains { base.hasPrefix($0) }
            || ["gfw", "greatfire", "cn", "private", "apple-cn", "google-cn"].contains(base)
    }
}

public struct GeoSiteDatabase: Sendable {
    struct Ref: Sendable { let category: Int32; let attributes: Int32; let kind: GeoSiteMatchKind; let value: String }

    let categories: [String]
    let attributeSets: [[String]]
    let full: [String: [Ref]]
    let suffix: [String: [Ref]]
    let keywords: [Ref]
    let regexes: [Ref]
    public var categoryCount: Int { categories.count }
    public var categoryNames: [String] { categories }

    public init(data: Data) throws {
        var categories: [String] = []
        var attributeSets: [[String]] = [[]]
        var attributeIndex: [[String]: Int32] = [[]: 0]
        var full: [String: [Ref]] = [:], suffix: [String: [Ref]] = [:]
        var keywords: [Ref] = [], regexes: [Ref] = []
        try data.withUnsafeBytes { raw in
            var list = ProtoReader(raw)
            while !list.atEnd {
                let (field, wire) = try list.tag()
                guard field == 1, wire == 2 else { try list.skip(wireType: wire); continue }
                let siteRange = try list.lengthDelimited()
                var site = ProtoReader(raw, from: siteRange.lowerBound, to: siteRange.upperBound)
                let category = Int32(categories.count)
                categories.append("")
                while !site.atEnd {
                    let (field, wire) = try site.tag()
                    if field == 1, wire == 2 {
                        categories[Int(category)] = site.string(try site.lengthDelimited()).lowercased()
                    } else if field == 2, wire == 2 {
                        let domainRange = try site.lengthDelimited()
                        var domain = ProtoReader(raw, from: domainRange.lowerBound, to: domainRange.upperBound)
                        var kind = GeoSiteMatchKind.keyword, value = "", attributes: [String] = []
                        while !domain.atEnd {
                            let (field, wire) = try domain.tag()
                            switch (field, wire) {
                            case (1, 0): kind = GeoSiteMatchKind(rawValue: Int(try domain.varint())) ?? .keyword
                            case (2, 2): value = domain.string(try domain.lengthDelimited())
                            case (3, 2):
                                let attributeRange = try domain.lengthDelimited()
                                var attribute = ProtoReader(raw, from: attributeRange.lowerBound, to: attributeRange.upperBound)
                                while !attribute.atEnd {
                                    let (field, wire) = try attribute.tag()
                                    if field == 1, wire == 2 { attributes.append(attribute.string(try attribute.lengthDelimited()).lowercased()) }
                                    else { try attribute.skip(wireType: wire) }
                                }
                            default: try domain.skip(wireType: wire)
                            }
                        }
                        let set: Int32
                        if let known = attributeIndex[attributes] { set = known } else {
                            set = Int32(attributeSets.count)
                            attributeSets.append(attributes)
                            attributeIndex[attributes] = set
                        }
                        let lowered = value.lowercased()
                        let ref = Ref(category: category, attributes: set, kind: kind, value: lowered)
                        switch kind {
                        case .full: full[lowered, default: []].append(ref)
                        case .suffix: suffix[lowered, default: []].append(ref)
                        case .keyword: keywords.append(ref)
                        case .regex: regexes.append(ref)
                        }
                    } else {
                        try site.skip(wireType: wire)
                    }
                }
            }
        }
        guard !categories.isEmpty else { throw EditorError("geosite.dat 中没有数据。") }
        self.categories = categories
        self.attributeSets = attributeSets
        self.full = full
        self.suffix = suffix
        self.keywords = keywords
        self.regexes = regexes
    }

    /// Every entry that matches the domain (lowercased, without a trailing dot).
    public func matches(for domain: String) -> [GeoSiteMatch] {
        let host = GeoLookup.normalizedHost(domain)
        guard !host.isEmpty else { return [] }
        var refs = full[host] ?? []
        var labels = host[...]
        while true {
            refs += suffix[String(labels)] ?? []
            guard let dot = labels.firstIndex(of: ".") else { break }
            labels = labels[labels.index(after: dot)...]
        }
        refs += keywords.filter { host.contains($0.value) }
        refs += regexes.filter { host.range(of: $0.value, options: .regularExpression) != nil }
        return refs.map {
            GeoSiteMatch(category: categories[Int($0.category)], attributes: attributeSets[Int($0.attributes)], kind: $0.kind, value: $0.value)
        }
    }

    /// The rule sets that contain the domain, named as in meta-rules-dat. With `available` (the
    /// catalog's names), only sets that exist there are returned, and `name@!attr` variants are
    /// included when the domain's entry lacks that attribute.
    public func hits(for domain: String, available: Set<String>? = nil) -> [GeoSiteHit] {
        let byCategory = Dictionary(grouping: matches(for: domain), by: \.category)
        var hits: [GeoSiteHit] = []
        for (category, matches) in byCategory {
            var names: [String: [GeoSiteMatch]] = [category: matches]
            for match in matches {
                for attribute in match.attributes { names["\(category)@\(attribute)", default: []].append(match) }
            }
            if let available {
                for name in available where name.hasPrefix("\(category)@!") {
                    let attribute = String(name.dropFirst(category.count + 2))
                    let without = matches.filter { !$0.attributes.contains(attribute) }
                    if !without.isEmpty { names[name] = without }
                }
            }
            for (name, matches) in names where available?.contains(name) ?? true {
                hits.append(GeoSiteHit(name: name, matches: matches))
            }
        }
        // Specific sets first: a site's own set before broad categories, plain names before variants.
        return hits.sorted { lhs, rhs in
            let left = (lhs.isBroad, lhs.name.contains("@"), lhs.name)
            let right = (rhs.isBroad, rhs.name.contains("@"), rhs.name)
            if left.0 != right.0 { return !left.0 }
            if left.1 != right.1 { return !left.1 }
            return left.2 < right.2
        }
    }
}

// MARK: - geoip

/// An IPv4 or IPv6 address as a 128-bit number (IPv4 mapped into ::ffff:0:0/96).
public struct IPAddr: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: UInt128
    public let isV4: Bool

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") { trimmed = String(trimmed.dropFirst().dropLast()) }
        if let zone = trimmed.firstIndex(of: "%") { trimmed = String(trimmed[..<zone]) }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            let host = UInt32(bigEndian: v4.s_addr)
            self.init(v4: host)
        } else if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            self.init(bytes: bytes)
        } else {
            return nil
        }
    }

    public init(v4: UInt32) {
        value = (UInt128(0xffff) << 32) | UInt128(v4)
        isV4 = true
    }

    public init(bytes: [UInt8]) {
        if bytes.count == 4 {
            self.init(v4: bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            return
        }
        // ::ffff:a.b.c.d is an IPv4 address.
        self.init(raw: bytes.prefix(16).reduce(UInt128(0)) { $0 << 8 | UInt128($1) })
    }

    /// The address's bit `index` counted from the top of its own width (32 or 128 bits).
    func bit(_ index: Int) -> Bool {
        let width = isV4 ? 32 : 128
        return (value >> (width - 1 - index)) & 1 == 1
    }

    public var description: String {
        if isV4 {
            let v4 = UInt32(truncatingIfNeeded: value)
            return "\(v4 >> 24).\(v4 >> 16 & 0xff).\(v4 >> 8 & 0xff).\(v4 & 0xff)"
        }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            for index in 0..<16 { buffer[index] = UInt8(truncatingIfNeeded: value >> (8 * (15 - index))) }
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
        return String(cString: text)
    }

    /// `address/prefix` with host bits cleared, for an IP-CIDR rule.
    public func network(prefix: Int) -> String {
        let width = isV4 ? 32 : 128
        let hostBits = width - max(0, min(prefix, width))
        let mask: UInt128 = hostBits >= 128 ? 0 : ~UInt128(0) << hostBits
        let base = isV4 ? IPAddr(v4: UInt32(truncatingIfNeeded: value & mask)) : IPAddr(raw: value & mask)
        return "\(base)/\(prefix)"
    }

    init(raw: UInt128) {
        value = raw
        isV4 = raw >> 32 == 0xffff
    }

    public static func < (lhs: IPAddr, rhs: IPAddr) -> Bool { lhs.value < rhs.value }

    /// 198.18.0.0/15: the range Mihomo and similar proxies hand out as fake IPs. An answer here
    /// came from a proxy on this machine, not from the site's real DNS.
    public var isFakeIP: Bool { isV4 && UInt32(truncatingIfNeeded: value) >> 17 == 0xC612 >> 1 }

    /// Private, loopback, link-local and similar ranges that never leave the local network.
    public var isPrivate: Bool {
        if isV4 {
            let v4 = UInt32(truncatingIfNeeded: value)
            let ranges: [(UInt32, Int)] = [(0x0A00_0000, 8), (0xAC10_0000, 12), (0xC0A8_0000, 16), (0x7F00_0000, 8),
                                           (0xA9FE_0000, 16), (0x6440_0000, 10), (0x0000_0000, 8)]
            return ranges.contains { base, prefix in v4 >> (32 - prefix) == base >> (32 - prefix) }
        }
        return value == 1 || value >> 121 == 0x7e || value >> 118 == 0x3fa  // ::1, fc00::/7, fe80::/10
    }
}

public struct GeoIPDatabase: Sendable {
    let categories: [String]
    /// Per category: sorted, merged [start, end] ranges.
    let ranges: [[(UInt128, UInt128)]]
    public var categoryCount: Int { categories.count }

    public init(data: Data) throws {
        var categories: [String] = []
        var ranges: [[(UInt128, UInt128)]] = []
        try data.withUnsafeBytes { raw in
            var list = ProtoReader(raw)
            while !list.atEnd {
                let (field, wire) = try list.tag()
                guard field == 1, wire == 2 else { try list.skip(wireType: wire); continue }
                let entryRange = try list.lengthDelimited()
                var entry = ProtoReader(raw, from: entryRange.lowerBound, to: entryRange.upperBound)
                var name = "", cidrs: [(UInt128, UInt128)] = []
                while !entry.atEnd {
                    let (field, wire) = try entry.tag()
                    if field == 1, wire == 2 {
                        name = entry.string(try entry.lengthDelimited()).lowercased()
                    } else if field == 2, wire == 2 {
                        let cidrRange = try entry.lengthDelimited()
                        var cidr = ProtoReader(raw, from: cidrRange.lowerBound, to: cidrRange.upperBound)
                        var ip: [UInt8] = [], prefix = 0
                        while !cidr.atEnd {
                            let (field, wire) = try cidr.tag()
                            if field == 1, wire == 2 { ip = Array(UnsafeRawBufferPointer(rebasing: raw[try cidr.lengthDelimited()])) }
                            else if field == 2, wire == 0 { prefix = Int(try cidr.varint()) }
                            else { try cidr.skip(wireType: wire) }
                        }
                        guard ip.count == 4 || ip.count == 16 else { continue }
                        let address = IPAddr(bytes: ip)
                        let width = ip.count == 4 ? 32 : 128
                        let hostBits = width - min(prefix, width)
                        let span: UInt128 = hostBits >= 128 ? ~UInt128(0) : (UInt128(1) << hostBits) - 1
                        let start = address.value & ~span
                        cidrs.append((start, start | span))
                    } else {
                        try entry.skip(wireType: wire)
                    }
                }
                cidrs.sort { $0.0 < $1.0 }
                var merged: [(UInt128, UInt128)] = []
                for range in cidrs {
                    if let last = merged.last, range.0 <= last.1 &+ 1, last.1 != ~UInt128(0) {
                        merged[merged.count - 1].1 = max(last.1, range.1)
                    } else {
                        merged.append(range)
                    }
                }
                categories.append(name)
                ranges.append(merged)
            }
        }
        guard !categories.isEmpty else { throw EditorError("geoip.dat 中没有数据。") }
        self.categories = categories
        self.ranges = ranges
    }

    /// geoip rule sets (country codes and lists such as `private`, `telegram`) containing the address.
    public func names(for address: IPAddr) -> [String] {
        var found: [String] = []
        for (index, list) in ranges.enumerated() {
            var low = 0, high = list.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if list[middle].1 < address.value { low = middle + 1 }
                else if list[middle].0 > address.value { high = middle - 1 }
                else { found.append(categories[index]); break }
            }
        }
        return found.sorted()
    }
}

// MARK: - MaxMind DB (ASN)

/// Reader for MaxMind DB files such as GeoLite2-ASN.mmdb (the file Mihomo uses for IP-ASN rules).
public struct MaxMindDatabase: Sendable {
    public indirect enum Value: Sendable, Equatable {
        case string(String), double(Double), bytes([UInt8]), unsigned(UInt64), signed(Int64), bool(Bool)
        case map([String: Value]), array([Value])

        public var string: String? { if case .string(let value) = self { value } else { nil } }
        public var unsigned: UInt64? { if case .unsigned(let value) = self { value } else { nil } }
        public subscript(key: String) -> Value? { if case .map(let map) = self { map[key] } else { nil } }
    }

    let bytes: [UInt8]
    let nodeCount: Int
    let recordSize: Int
    let ipVersion: Int
    let dataStart: Int
    let ipv4Start: Int
    public let databaseType: String
    public let buildDate: Date?

    static let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard let markerIndex = Self.lastIndex(of: Self.marker, in: bytes) else { throw EditorError("ASN 数据库文件无法识别。") }
        let metadataStart = markerIndex + Self.marker.count
        var decoder = Decoder(bytes: bytes, base: metadataStart)
        let metadata = try decoder.value(at: metadataStart).0
        guard let nodes = metadata["node_count"]?.unsigned, let record = metadata["record_size"]?.unsigned,
              [24, 28, 32].contains(record) else { throw EditorError("ASN 数据库的元数据不完整。") }
        nodeCount = Int(nodes)
        recordSize = Int(record)
        ipVersion = Int(metadata["ip_version"]?.unsigned ?? 6)
        databaseType = metadata["database_type"]?.string ?? ""
        buildDate = metadata["build_epoch"]?.unsigned.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let treeSize = recordSize * 2 / 8 * nodeCount
        dataStart = treeSize + 16
        guard dataStart <= bytes.count else { throw EditorError("ASN 数据库文件不完整。") }
        self.bytes = bytes
        // IPv4 addresses live under 96 zero bits in an IPv6 tree.
        var node = 0
        if ipVersion == 6 {
            for _ in 0..<96 where node < nodeCount { node = Self.record(bytes, node: node, right: false, size: recordSize) }
        }
        ipv4Start = node
    }

    static func lastIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        var index = bytes.count - pattern.count
        let floor = max(0, bytes.count - 256 * 1024)
        while index >= floor {
            if bytes[index] == pattern[0], Array(bytes[index..<(index + pattern.count)]) == pattern { return index }
            index -= 1
        }
        return nil
    }

    static func record(_ bytes: [UInt8], node: Int, right: Bool, size: Int) -> Int {
        let base = node * size * 2 / 8
        switch size {
        case 24:
            let offset = base + (right ? 3 : 0)
            return Int(bytes[offset]) << 16 | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
        case 28:
            if right {
                return (Int(bytes[base + 3]) & 0x0f) << 24 | Int(bytes[base + 4]) << 16 | Int(bytes[base + 5]) << 8 | Int(bytes[base + 6])
            }
            return (Int(bytes[base + 3]) & 0xf0) << 20 | Int(bytes[base]) << 16 | Int(bytes[base + 1]) << 8 | Int(bytes[base + 2])
        default:
            let offset = base + (right ? 4 : 0)
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
    }

    /// The record for the address and the prefix length of the network it belongs to.
    public func lookup(_ address: IPAddr) throws -> (Value, prefix: Int)? {
        let width = address.isV4 ? 32 : 128
        if !address.isV4, ipVersion == 4 { return nil }
        var node = address.isV4 ? ipv4Start : 0
        var depth = 0
        while depth < width, node < nodeCount {
            node = Self.record(bytes, node: node, right: address.bit(depth), size: recordSize)
            depth += 1
        }
        guard node > nodeCount else { return nil }
        let offset = (node - nodeCount) - 16 + dataStart
        guard offset < bytes.count else { throw EditorError("ASN 数据库记录越界。") }
        var decoder = Decoder(bytes: bytes, base: dataStart)
        return (try decoder.value(at: offset).0, depth)
    }

    struct Decoder {
        let bytes: [UInt8]
        /// Pointers are relative to this offset (the data section, or the metadata).
        let base: Int

        func byte(_ index: Int) throws -> Int {
            guard index < bytes.count else { throw EditorError("ASN 数据库记录越界。") }
            return Int(bytes[index])
        }

        func number(_ start: Int, _ count: Int) throws -> UInt64 {
            guard start + count <= bytes.count, count <= 8 else { throw EditorError("ASN 数据库记录越界。") }
            return bytes[start..<(start + count)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        /// The value at `offset` and the offset just after it.
        mutating func value(at offset: Int) throws -> (Value, Int) {
            var position = offset
            let control = try byte(position)
            position += 1
            var type = control >> 5
            if type == 1 {  // pointer
                let size = (control >> 3) & 0x3, low = control & 0x7
                let pointer: Int
                switch size {
                case 0: pointer = low << 8 | (try byte(position))
                case 1: pointer = (low << 16 | Int(try number(position, 2))) + 2048
                case 2: pointer = (low << 24 | Int(try number(position, 3))) + 526_336
                default: pointer = Int(try number(position, 4))
                }
                let target = base + pointer
                guard target != offset else { throw EditorError("ASN 数据库记录无效。") }
                return (try value(at: target).0, position + size + 1)
            }
            if type == 0 {
                type = 7 + (try byte(position))
                position += 1
            }
            var size = control & 0x1f
            switch size {
            case 29: size = 29 + (try byte(position)); position += 1
            case 30: size = 285 + Int(try number(position, 2)); position += 2
            case 31: size = 65_821 + Int(try number(position, 3)); position += 3
            default: break
            }
            switch type {
            case 2:
                guard position + size <= bytes.count else { throw EditorError("ASN 数据库记录越界。") }
                return (.string(String(decoding: bytes[position..<(position + size)], as: UTF8.self)), position + size)
            case 3: return (.double(Double(bitPattern: try number(position, 8))), position + 8)
            case 4:
                guard position + size <= bytes.count else { throw EditorError("ASN 数据库记录越界。") }
                return (.bytes(Array(bytes[position..<(position + size)])), position + size)
            case 5, 6, 9: return (.unsigned(try number(position, size)), position + size)
            case 10: return (.bytes(Array(bytes[position..<min(bytes.count, position + size)])), position + size)
            case 8: return (.signed(Int64(Int32(truncatingIfNeeded: try number(position, size)))), position + size)
            case 7:
                var map: [String: Value] = [:]
                for _ in 0..<size {
                    let (key, afterKey) = try value(at: position)
                    let (entry, afterValue) = try value(at: afterKey)
                    if let key = key.string { map[key] = entry }
                    position = afterValue
                }
                return (.map(map), position)
            case 11:
                var array: [Value] = []
                for _ in 0..<size {
                    let (entry, next) = try value(at: position)
                    array.append(entry)
                    position = next
                }
                return (.array(array), position)
            case 14: return (.bool(size != 0), position)
            case 15: return (.double(Double(Float(bitPattern: UInt32(try number(position, 4))))), position + 4)
            default: throw EditorError("ASN 数据库中有无法识别的数据类型（\(type)）。")
            }
        }
    }
}

/// The autonomous system an address belongs to.
public struct ASNInfo: Sendable, Hashable {
    public let number: Int
    public let organization: String
    /// The network the database lists the address under, e.g. `104.16.0.0/13`.
    public let network: String
}

// MARK: - Files

/// The geodata files and where they come from.
public enum GeoDataFile: String, Sendable, CaseIterable, Identifiable {
    case geosite = "geosite.dat"
    case geoip = "geoip.dat"
    case asn = "GeoLite2-ASN.mmdb"

    public var id: String { rawValue }
    public var url: URL { URL(string: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/\(rawValue)")! }
    public var checksumURL: URL { URL(string: url.absoluteString + ".sha256sum")! }

    public var title: String {
        switch self {
        case .geosite: "域名规则集（geosite.dat）"
        case .geoip: "IP 规则集（geoip.dat）"
        case .asn: "ASN 数据库（GeoLite2-ASN.mmdb）"
        }
    }

    /// Approximate size, shown before downloading.
    public var approximateSize: String {
        switch self {
        case .geosite: "约 4 MB"
        case .geoip: "约 17 MB"
        case .asn: "约 9 MB"
        }
    }
}

/// Downloads a file to a temporary location. Replaced in tests.
public protocol GeoDataFetching: Sendable {
    func download(_ url: URL) async throws -> URL
    func text(_ url: URL) async throws -> String
}

public struct URLSessionGeoDataFetcher: GeoDataFetching {
    public init() {}

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    public func download(_ url: URL) async throws -> URL {
        let (location, response) = try await Self.session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EditorError("下载 \(url.lastPathComponent) 失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        return location
    }

    public func text(_ url: URL) async throws -> String {
        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EditorError("下载 \(url.lastPathComponent) 失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where the downloaded files live and the parsed databases, loaded once on first use.
public actor GeoDataStore {
    public struct Status: Sendable, Equatable {
        /// Download date of each file that is present.
        public var files: [String: Date]
        public var isComplete: Bool { GeoDataFile.allCases.allSatisfy { files[$0.rawValue] != nil } }
        public var updated: Date? { files.values.min() }
        public func has(_ file: GeoDataFile) -> Bool { files[file.rawValue] != nil }
    }

    public static let shared = GeoDataStore()

    public nonisolated let directory: URL
    let fetcher: GeoDataFetching
    private var geositeCache: GeoSiteDatabase?
    private var geoipCache: GeoIPDatabase?
    private var asnCache: MaxMindDatabase?

    public static var defaultDirectory: URL {
        SessionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("GeoData", isDirectory: true)
    }

    public init(directory: URL = GeoDataStore.defaultDirectory, fetcher: GeoDataFetching = URLSessionGeoDataFetcher()) {
        self.directory = directory
        self.fetcher = fetcher
    }

    func path(_ file: GeoDataFile) -> URL { directory.appendingPathComponent(file.rawValue) }

    public func status() -> Status {
        var files: [String: Date] = [:]
        for file in GeoDataFile.allCases {
            if let date = (try? FileManager.default.attributesOfItem(atPath: path(file).path))?[.modificationDate] as? Date {
                files[file.rawValue] = date
            }
        }
        return Status(files: files)
    }

    /// Downloads each file, checks it against its published SHA-256 and replaces the old copy.
    public func download(_ files: [GeoDataFile] = GeoDataFile.allCases, progress: (@Sendable (GeoDataFile) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in files {
            progress?(file)
            let expected = try await fetcher.text(file.checksumURL).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
            let temporary = try await fetcher.download(file.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard expected.count == 64, actual == expected else {
                throw EditorError("\(file.rawValue) 校验失败，没有替换本机已有的文件。请稍后重试。")
            }
            // Parse before replacing, so a broken file never replaces a good one.
            try Self.check(file, data: data)
            let destination = path(file)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            switch file {
            case .geosite: geositeCache = nil
            case .geoip: geoipCache = nil
            case .asn: asnCache = nil
            }
        }
    }

    static func check(_ file: GeoDataFile, data: Data) throws {
        switch file {
        case .geosite: _ = try GeoSiteDatabase(data: data)
        case .geoip: _ = try GeoIPDatabase(data: data)
        case .asn: _ = try MaxMindDatabase(data: data)
        }
    }

    public func geosite() throws -> GeoSiteDatabase? {
        if let geositeCache { return geositeCache }
        guard let data = try? Data(contentsOf: path(.geosite), options: .mappedIfSafe) else { return nil }
        geositeCache = try GeoSiteDatabase(data: data)
        return geositeCache
    }

    public func geoip() throws -> GeoIPDatabase? {
        if let geoipCache { return geoipCache }
        guard let data = try? Data(contentsOf: path(.geoip), options: .mappedIfSafe) else { return nil }
        geoipCache = try GeoIPDatabase(data: data)
        return geoipCache
    }

    public func asn() throws -> MaxMindDatabase? {
        if let asnCache { return asnCache }
        guard let data = try? Data(contentsOf: path(.asn)) else { return nil }
        asnCache = try MaxMindDatabase(data: data)
        return asnCache
    }
}

// MARK: - Lookups

public enum GeoLookup {
    static func normalizedHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let urlHost = url.host(), host.contains("://") { host = urlHost }
        if host.hasPrefix("+.") || host.hasPrefix("*.") { host = String(host.dropFirst(2)) }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// A domain name a user or a search result may give (not an IP, at least one dot).
    public static func domain(in text: String) -> String? {
        let host = normalizedHost(text)
        guard IPAddr(host) == nil, host.contains("."),
              host.range(of: #"^[a-z0-9\p{L}]([a-z0-9\p{L}-]*[a-z0-9\p{L}])?(\.[a-z0-9\p{L}]([a-z0-9\p{L}-]*[a-z0-9\p{L}])?)+$"#, options: .regularExpression) != nil
        else { return nil }
        return host
    }
}

/// Everything known locally about one IP address.
public struct IPReport: Sendable, Hashable, Identifiable {
    public let address: IPAddr
    public let geoip: [String]
    public let asn: ASNInfo?
    public let isPrivate: Bool
    public var id: String { address.description }
}

extension GeoDataStore {
    public func report(for address: IPAddr) throws -> IPReport {
        let geoip = try geoip()?.names(for: address) ?? []
        var asn: ASNInfo?
        if let database = try self.asn(), let (record, prefix) = try database.lookup(address),
           let number = record["autonomous_system_number"]?.unsigned {
            asn = ASNInfo(number: Int(number), organization: record["autonomous_system_organization"]?.string ?? "",
                          network: address.network(prefix: prefix))
        }
        return IPReport(address: address, geoip: geoip, asn: asn, isPrivate: address.isPrivate)
    }

    /// geosite rule sets containing the domain; nil when geosite.dat is not downloaded.
    public func ruleSets(for domain: String, available: Set<String>? = nil) throws -> [GeoSiteHit]? {
        guard let database = try geosite() else { return nil }
        return database.hits(for: domain, available: available)
    }
}
