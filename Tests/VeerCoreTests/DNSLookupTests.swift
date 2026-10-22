import Foundation
import Testing
@testable import VeerCore

struct DNSLookupTests {
    /// A response for www.example.com: a CNAME (with name compression) and two A records.
    static func response(id: UInt16, rcode: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x81, 0x80 | rcode, 0, 1, 0, rcode == 0 ? 3 : 0, 0, 0, 0, 0]
        bytes += [3] + Array("www".utf8) + [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        guard rcode == 0 else { return bytes }
        // www.example.com CNAME edge.example.com (pointer to "example.com" at offset 16)
        let edge: [UInt8] = [4] + Array("edge".utf8) + [0xc0, 16]
        bytes += [0xc0, 12, 0, 5, 0, 1, 0, 0, 0x0e, 0x10, 0, UInt8(edge.count)] + edge
        let edgeOffset = bytes.count - edge.count
        bytes += [0xc0, UInt8(edgeOffset), 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        bytes += [0xc0, UInt8(edgeOffset), 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 35]
        return bytes
    }

    @Test func messagesEncodeAndParse() throws {
        let query = try DNSMessage.query("www.example.com", type: .aaaa, id: 0x1234)
        #expect(query.prefix(4) == [0x12, 0x34, 0x01, 0x00] && query.suffix(4) == [0, 28, 0, 1])
        #expect(throws: EditorError.self) { try DNSMessage.query("例子.中国", type: .a, id: 1) }
        let (status, answers) = try DNSMessage.parse(Self.response(id: 7), id: 7)
        #expect(status == "NOERROR")
        #expect(answers.map(\.type) == ["CNAME", "A", "A"])
        #expect(answers[0].data == "edge.example.com" && answers[0].ttl == 3600)
        #expect(answers[1].name == "edge.example.com" && answers[1].data == "93.184.216.34" && answers[1].address != nil)
        #expect(try DNSMessage.parse(Self.response(id: 7, rcode: 3), id: 7).status == "NXDOMAIN")
        #expect(throws: EditorError.self) { try DNSMessage.parse(Self.response(id: 7), id: 8) }
        #expect(throws: EditorError.self) { try DNSMessage.parse([0, 1, 2], id: nil) }
    }

    @Test func dohSendsTheQueryInTheURL() async throws {
        let transport = RoutedTransport([("dns.alidns.com", 200, "")])
        transport.binaryBody = Data(Self.response(id: 0))
        let result = try await DNSResolver(transport: transport).lookup("https://www.example.com/x", type: .a,
                                                                      server: .doh(URL(string: "https://dns.alidns.com/dns-query")!))
        #expect(result.domain == "www.example.com" && result.answers.count == 3 && result.status == "NOERROR")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/dns-message")
        let encoded = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dns" }?.value)
        #expect(!encoded.contains("=") && !encoded.contains("+") && !encoded.contains("/"))
        await #expect(throws: EditorError.self) { try await DNSResolver(transport: transport).lookup("not a domain", type: .a, server: .system) }
    }

    @Test func serversParseLikeMihomo() {
        #expect(DNSServer(mihomo: "223.5.5.5") == .udp(host: "223.5.5.5", port: 53))
        #expect(DNSServer(mihomo: "udp://119.29.29.29:5353") == .udp(host: "119.29.29.29", port: 5353))
        #expect(DNSServer(mihomo: "[2400:3200::1]:53") == .udp(host: "2400:3200::1", port: 53))
        #expect(DNSServer(mihomo: "2400:3200::1") == .udp(host: "2400:3200::1", port: 53))
        #expect(DNSServer(mihomo: "https://dns.alidns.com/dns-query#h3=true") == .doh(URL(string: "https://dns.alidns.com/dns-query")!))
        #expect(DNSServer(mihomo: "system") == .system)
        #expect(DNSServer(mihomo: "tls://1.1.1.1") == nil && DNSServer(mihomo: "dhcp://en0") == nil && DNSServer(mihomo: "") == nil)
        let config = """
        dns:
          enable: true
          default-nameserver: [223.5.5.5, 119.29.29.29]
          nameserver:
            - https://dns.alidns.com/dns-query
            - tls://dns.google
          nameserver-policy:
            "geosite:cn": [223.5.5.5, "https://doh.pub/dns-query"]
            "+.example.com": "udp://10.0.0.1"
        """
        #expect(DNSServer.configured(in: config) == ["https://dns.alidns.com/dns-query", "tls://dns.google", "223.5.5.5", "119.29.29.29",
                                                    "udp://10.0.0.1", "https://doh.pub/dns-query"])
        #expect(DNSServer.configured(in: "proxies: []") == [])
    }
}

/// Real DNS servers: `VEER_NETWORK_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_NETWORK_TESTS"] != nil))
struct RealDNSTests {
    @Test func realServersAnswer() async throws {
        let resolver = DNSResolver()
        for server in DNSServer.presets.map(\.server) {
            let result = try await resolver.lookup("www.jal.co.jp", type: .a, server: server)
            print("REAL dns \(server.label) \(result.status) \(Int(result.duration * 1000)) ms → \(result.answers.map { "\($0.type) \($0.data)" }.joined(separator: ", "))")
            #expect(result.answers.contains { $0.address != nil })
        }
        let v6 = try await resolver.lookup("www.google.com", type: .aaaa, server: .udp(host: "223.5.5.5", port: 53))
        print("REAL dns AAAA \(v6.answers.map(\.data))")
        let missing = try await resolver.lookup("no-such-host.veer-example.invalid", type: .a, server: DNSServer.presets[1].server)
        #expect(missing.status == "NXDOMAIN")
    }
}
