import CryptoKit
import Foundation
import Testing
@testable import VeerCore

/// Minimal protobuf and MaxMind DB writers for fixtures.
enum GeoFixture {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    static func field(_ number: Int, _ payload: [UInt8]) -> [UInt8] { varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload }
    static func field(_ number: Int, _ text: String) -> [UInt8] { field(number, Array(text.utf8)) }
    static func field(_ number: Int, varint value: UInt64) -> [UInt8] { varint(UInt64(number << 3)) + varint(value) }

    /// geosite.dat: [(category, [(type, value, attributes)])].
    static func geosite(_ sites: [(String, [(Int, String, [String])])]) -> Data {
        Data(sites.flatMap { name, domains in
            field(1, field(1, name.uppercased()) + domains.flatMap { type, value, attributes in
                field(2, field(1, varint: UInt64(type)) + field(2, value) + attributes.flatMap { field(3, field(1, $0) + field(2, varint: 1)) })
            })
        })
    }

    /// geoip.dat: [(category, [(ip bytes, prefix)])].
    static func geoip(_ entries: [(String, [([UInt8], Int)])]) -> Data {
        Data(entries.flatMap { name, cidrs in
            field(1, field(1, name.uppercased()) + cidrs.flatMap { ip, prefix in field(2, field(1, ip) + field(2, varint: UInt64(prefix))) })
        })
    }

    static func mmdbString(_ text: String) -> [UInt8] {
        let count = text.utf8.count
        let header: [UInt8] = count < 29 ? [UInt8(2 << 5 | count)] : [UInt8(2 << 5 | 29), UInt8(count - 29)]
        return header + Array(text.utf8)
    }
    static func mmdbUInt(_ type: Int, _ value: UInt64, bytes: Int) -> [UInt8] {
        let payload = (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        if type <= 7 { return [UInt8(type << 5 | bytes)] + payload }
        return [UInt8(bytes), UInt8(type - 7)] + payload
    }
    static func mmdbMap(_ pairs: [(String, [UInt8])]) -> [UInt8] { [UInt8(7 << 5 | pairs.count)] + pairs.flatMap { mmdbString($0.0) + $0.1 } }

    /// An IPv4 MaxMind DB with one network.
    static func asnDatabase(network: [UInt8], prefix: Int, number: UInt64, organization: String) -> Data {
        let nodeCount = prefix
        var tree: [UInt8] = []
        let address = network.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        for depth in 0..<prefix {
            let next = depth == prefix - 1 ? nodeCount + 16 : depth + 1
            let bit = (address >> (31 - UInt32(depth))) & 1 == 1
            let left = bit ? nodeCount : next, right = bit ? next : nodeCount
            for record in [left, right] { tree += [UInt8(record >> 16 & 0xff), UInt8(record >> 8 & 0xff), UInt8(record & 0xff)] }
        }
        let record = mmdbMap([("autonomous_system_number", mmdbUInt(6, number, bytes: 4)),
                              ("autonomous_system_organization", mmdbString(organization))])
        let metadata = mmdbMap([("node_count", mmdbUInt(6, UInt64(nodeCount), bytes: 4)), ("record_size", mmdbUInt(5, 24, bytes: 2)),
                                ("ip_version", mmdbUInt(5, 4, bytes: 2)), ("database_type", mmdbString("GeoLite2-ASN")),
                                ("build_epoch", mmdbUInt(9, 1_760_000_000, bytes: 8))])
        return Data(tree + [UInt8](repeating: 0, count: 16) + record + MaxMindDatabase.marker + metadata)
    }
}

struct GeoDataTests {
    static let geosite = GeoFixture.geosite([
        ("google", [(2, "google.com", []), (2, "google.cn", ["cn"]), (3, "www.gstatic.com", []), (0, "googleapis", [])]),
        ("jal", [(2, "jal.co.jp", []), (2, "jal.com", [])]),
        ("category-airlines", [(2, "jal.co.jp", []), (1, #"^ana\.co\.jp$"#, [])]),
        ("airchina", [(2, "airchina.com", []), (2, "airchina.com.cn", ["cn"])]),
    ])

    @Test func geositeFindsSetsByEntryKind() throws {
        let database = try GeoSiteDatabase(data: Self.geosite)
        #expect(database.categoryCount == 4)
        #expect(database.hits(for: "book.jal.co.jp").map(\.name) == ["jal", "category-airlines"])
        // Full, suffix and keyword entries, case and trailing dots ignored.
        #expect(database.matches(for: "WWW.gstatic.com.").map(\.kind) == [.full])
        let keyword = try #require(database.hits(for: "storage.googleapis.net").first)
        #expect(keyword.name == "google" && keyword.geositeRuleOnly)
        #expect(database.hits(for: "ana.co.jp").first?.geositeRuleOnly == true)
        #expect(database.hits(for: "example.org").isEmpty)
    }

    @Test func geositeNamesAttributeVariantsLikeTheCatalog() throws {
        let database = try GeoSiteDatabase(data: Self.geosite)
        let available: Set = ["airchina", "airchina@!cn", "airchina@cn", "google", "google@cn", "google@!cn"]
        #expect(database.hits(for: "www.airchina.com", available: available).map(\.name) == ["airchina", "airchina@!cn"])
        #expect(database.hits(for: "airchina.com.cn", available: available).map(\.name) == ["airchina", "airchina@cn"])
        #expect(database.hits(for: "maps.google.cn", available: available).map(\.name) == ["google", "google@cn"])
        // Without a catalog, attribute variants still appear; only sets in the catalog are kept with one.
        #expect(database.hits(for: "google.cn").map(\.name) == ["google", "google@cn"])
        #expect(database.hits(for: "jal.com", available: ["google"]).isEmpty)
    }

    @Test func geoipFindsCountryAndListSets() throws {
        let data = GeoFixture.geoip([
            ("cn", [([1, 0, 1, 0], 24), ([1, 0, 2, 0], 23)]),
            ("private", [([10, 0, 0, 0], 8), ([192, 168, 0, 0], 16), ([0xfc] + [UInt8](repeating: 0, count: 15), 7)]),
            ("telegram", [([91, 108, 4, 0], 22), ([0x20, 0x01, 0x0b, 0x28, 0xf2, 0x3d] + [UInt8](repeating: 0, count: 10), 48)]),
        ])
        let database = try GeoIPDatabase(data: data)
        #expect(database.names(for: IPAddr("1.0.3.255")!) == ["cn"])
        #expect(database.names(for: IPAddr("1.0.4.0")!).isEmpty)
        #expect(database.names(for: IPAddr("192.168.31.1")!) == ["private"])
        #expect(database.names(for: IPAddr("91.108.7.1")!) == ["telegram"])
        #expect(database.names(for: IPAddr("2001:b28:f23d::1")!) == ["telegram"])
        #expect(database.names(for: IPAddr("fd00::1")!) == ["private"])
    }

    @Test func addressesParseAndPrint() {
        #expect(IPAddr("1.1.1.1")?.description == "1.1.1.1" && IPAddr("1.1.1.1")?.isV4 == true)
        #expect(IPAddr("[2606:4700::1111]")?.description == "2606:4700::1111")
        #expect(IPAddr("::ffff:8.8.8.8")?.description == "8.8.8.8")
        #expect(IPAddr("104.16.132.229")?.network(prefix: 13) == "104.16.0.0/13")
        #expect(IPAddr("2606:4700:10::6816:84e5")?.network(prefix: 32) == "2606:4700::/32")
        #expect(IPAddr("example.com") == nil && IPAddr("1.2.3") == nil)
        #expect(IPAddr("192.168.1.1")!.isPrivate && IPAddr("fe80::1")!.isPrivate && !IPAddr("8.8.8.8")!.isPrivate)
        #expect(IPAddr("198.18.15.42")!.isFakeIP && IPAddr("198.19.255.1")!.isFakeIP && !IPAddr("198.20.0.1")!.isFakeIP && !IPAddr("198.17.0.1")!.isFakeIP)
    }

    @Test func maxMindDatabaseReturnsTheASNAndNetwork() throws {
        let database = try MaxMindDatabase(data: GeoFixture.asnDatabase(network: [104, 16, 0, 0], prefix: 13, number: 13335, organization: "CLOUDFLARENET"))
        #expect(database.databaseType == "GeoLite2-ASN" && database.buildDate != nil)
        let (record, prefix) = try #require(try database.lookup(IPAddr("104.16.132.229")!))
        #expect(record["autonomous_system_number"]?.unsigned == 13335 && record["autonomous_system_organization"]?.string == "CLOUDFLARENET")
        #expect(prefix == 13)
        #expect(try database.lookup(IPAddr("8.8.8.8")!) == nil)
        #expect(throws: EditorError.self) { try MaxMindDatabase(data: Data("not a database".utf8)) }
    }

    @Test func domainsAreRecognized() {
        #expect(GeoLookup.domain(in: "https://www.jal.co.jp/jp/") == "www.jal.co.jp")
        #expect(GeoLookup.domain(in: "+.Netflix.com") == "netflix.com")
        #expect(GeoLookup.domain(in: "例子.中国") == "例子.中国")
        #expect(GeoLookup.domain(in: "Japan Airlines") == nil && GeoLookup.domain(in: "1.1.1.1") == nil && GeoLookup.domain(in: "localhost") == nil)
    }

    @Test func searchResultsNameTheSetsContainingTheirDomains() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-geodata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GeoFixture.geosite([("jal", [(2, "jal.co.jp", []), (2, "jal.com", [])]), ("tld-!cn", [(2, "jp", [])]),
                                ("geolocation-!cn", [(0, "jal", [])])]).write(to: directory.appendingPathComponent("geosite.dat"))
        let transport = RoutedTransport([("api.github.com", 404, ""), ("api.tavily.com", 200,
            #"{"results":[{"title":"JAL","url":"https://www.jal.co.jp/jp/","content":"Japan Airlines"},{"title":"JAL","url":"https://www.jal.com/","content":""}]}"#)])
        let service = WebSearchService(transport: transport, index: RuleSetIndex(transport: transport, cacheURL: nil), geo: GeoDataStore(directory: directory))
        let records = await service.search(["Japan Airlines"], config: .init(provider: .tavily, apiKey: "tvly-1"))
        let containing = try #require(records.first?.containing)
        #expect(containing.map(\.domain) == ["www.jal.co.jp", "www.jal.com"])
        #expect(containing[0].sets == ["jal", "tld-!cn"] && containing[0].geositeOnly == ["geolocation-!cn"])
        let message = SearchQueries.message(for: records, refused: [], lastRound: false)
        #expect(message.contains("www.jal.co.jp：jal、tld-!cn*") && message.contains("规则集文件不包含：geolocation-!cn"))
        // Without geodata the part is left out.
        let plain = await WebSearchService(transport: transport, index: RuleSetIndex(transport: transport, cacheURL: nil)).search(["jal.co.jp"], config: .init(provider: .catalogOnly))
        #expect(plain.first?.containing == nil)
    }

    /// Serves fixture files as if from GitHub.
    struct FixtureFetcher: GeoDataFetching {
        let files: [String: Data]
        var checksumOverride: String?

        func download(_ url: URL) async throws -> URL {
            guard let data = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporary)
            return temporary
        }

        func text(_ url: URL) async throws -> String {
            let name = url.lastPathComponent.replacingOccurrences(of: ".sha256sum", with: "")
            guard let data = files[name] else { throw URLError(.fileDoesNotExist) }
            let hash = checksumOverride ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return "\(hash)  \(name)\n"
        }
    }

    @Test func downloadsVerifyChecksumsBeforeReplacing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("veer-geodata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let geosite = GeoFixture.geosite([("jal", [(2, "jal.co.jp", [])])])
        let store = GeoDataStore(directory: directory, fetcher: FixtureFetcher(files: ["geosite.dat": geosite]))
        #expect(await store.status().has(.geosite) == false)
        #expect(try await store.ruleSets(for: "jal.co.jp") == nil)
        try await store.download([.geosite])
        #expect(await store.status().has(.geosite))
        #expect(try await store.ruleSets(for: "www.jal.co.jp")?.map(\.name) == ["jal"])

        let tampered = GeoDataStore(directory: directory, fetcher: FixtureFetcher(files: ["geosite.dat": GeoFixture.geosite([("x", [])])],
                                                                                 checksumOverride: String(repeating: "0", count: 64)))
        await #expect(throws: EditorError.self) { try await tampered.download([.geosite]) }
        // The good file is still there.
        #expect(try await GeoDataStore(directory: directory).ruleSets(for: "jal.co.jp")?.map(\.name) == ["jal"])
    }
}

/// Real MetaCubeX files: `VEER_GEODATA_DIR=<folder with geosite.dat, geoip.dat, GeoLite2-ASN.mmdb>`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_GEODATA_DIR"] != nil))
struct RealGeoDataTests {
    @Test func realFilesAnswer() async throws {
        let store = GeoDataStore(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["VEER_GEODATA_DIR"]!))
        var start = Date()
        let geosite = try #require(try await store.geosite())
        print(String(format: "REAL geosite: %d categories, %.2fs", geosite.categoryCount, Date().timeIntervalSince(start)))
        start = Date()
        let geoip = try #require(try await store.geoip())
        print(String(format: "REAL geoip: %d categories, %.2fs", geoip.categoryCount, Date().timeIntervalSince(start)))
        start = Date()
        _ = try #require(try await store.asn())
        print(String(format: "REAL asn: %.2fs", Date().timeIntervalSince(start)))
        for domain in ["www.jal.co.jp", "www.netflix.com", "chatgpt.com", "www.bilibili.com", "maps.google.cn"] {
            start = Date()
            let hits = try #require(try await store.ruleSets(for: domain))
            print(String(format: "REAL %@ (%.0f ms) → %@", domain, Date().timeIntervalSince(start) * 1000,
                         hits.prefix(12).map { $0.name + ($0.geositeRuleOnly ? "(仅GEOSITE)" : "") }.joined(separator: ", ")))
        }
        #expect(try await store.ruleSets(for: "www.netflix.com")?.contains { $0.name == "netflix" } == true)
        for ip in ["1.1.1.1", "223.5.5.5", "91.108.56.100", "2001:4860:4860::8888", "192.168.1.1"] {
            start = Date()
            let report = try await store.report(for: IPAddr(ip)!)
            print(String(format: "REAL %@ (%.0f ms) → geoip %@ asn %@", ip, Date().timeIntervalSince(start) * 1000,
                         report.geoip.joined(separator: ","), report.asn.map { "AS\($0.number) \($0.organization) \($0.network)" } ?? "-"))
        }
        #expect(try await store.report(for: IPAddr("223.5.5.5")!).geoip.contains("cn"))
        #expect(try await store.report(for: IPAddr("1.1.1.1")!).asn?.number == 13335)
    }
}
