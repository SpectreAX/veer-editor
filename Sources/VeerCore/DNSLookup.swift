import Foundation
import Network
import Yams

/// A DNS server the lookup tool can ask: the system resolver, DNS over HTTPS, or plain UDP.
public enum DNSServer: Sendable, Hashable, Identifiable {
    case system
    case doh(URL)
    case udp(host: String, port: UInt16)

    public var id: String { label }

    public var label: String {
        switch self {
        case .system: "系统 DNS"
        case .doh(let url): url.absoluteString
        case let .udp(host, port): port == 53 ? host : (host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")
        }
    }

    /// Well-known public resolvers.
    public static let presets: [(title: String, server: DNSServer)] = [
        ("系统 DNS", .system),
        ("阿里 DoH", .doh(URL(string: "https://dns.alidns.com/dns-query")!)),
        ("腾讯 DNSPod DoH", .doh(URL(string: "https://doh.pub/dns-query")!)),
        ("Cloudflare DoH", .doh(URL(string: "https://cloudflare-dns.com/dns-query")!)),
        ("Google DoH", .doh(URL(string: "https://dns.google/dns-query")!)),
        ("阿里 223.5.5.5（UDP）", .udp(host: "223.5.5.5", port: 53)),
    ]

    /// A server written as in a Mihomo config: `https://…`, `udp://host:port`, `host[:port]` or
    /// `system`. TLS, QUIC, TCP and DHCP servers are not supported here (nil).
    public init?(mihomo text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        guard !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        if lowered == "system" || lowered == "system://" { self = .system; return }
        if lowered.hasPrefix("https://") {
            guard let url = URL(string: value), url.host() != nil else { return nil }
            self = .doh(url)
            return
        }
        if lowered.contains("://") {
            guard lowered.hasPrefix("udp://") else { return nil }
            value = String(value.dropFirst(6))
        }
        var host = value, port: UInt16 = 53
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":") { guard let parsed = UInt16(rest.dropFirst()) else { return nil }; port = parsed }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            host = String(value[..<colon])
            guard let parsed = UInt16(value[value.index(after: colon)...]) else { return nil }
            port = parsed
        }
        guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9.:-]+$"#, options: .regularExpression) != nil else { return nil }
        self = .udp(host: host, port: port)
    }

    /// DNS servers named in a config's `dns` section, in order, without duplicates.
    public static func configured(in configText: String) -> [String] {
        guard let root = (try? Yams.load(yaml: configText)) as? [String: Any], let dns = root["dns"] as? [String: Any] else { return [] }
        var servers: [String] = []
        func add(_ value: Any?) {
            if let text = value as? String {
                for part in text.split(separator: ",") {
                    let server = part.trimmingCharacters(in: .whitespaces)
                    if !server.isEmpty, !servers.contains(server) { servers.append(server) }
                }
            } else if let list = value as? [Any] {
                list.forEach { add($0) }
            }
        }
        for key in ["nameserver", "default-nameserver", "proxy-server-nameserver", "direct-nameserver", "fallback"] { add(dns[key]) }
        if let policy = dns["nameserver-policy"] as? [String: Any] { policy.keys.sorted().forEach { add(policy[$0]) } }
        return servers
    }
}

public enum DNSRecordType: String, Sendable, CaseIterable, Identifiable {
    case a = "A", aaaa = "AAAA", cname = "CNAME"

    public var id: String { rawValue }
    var code: UInt16 {
        switch self {
        case .a: 1
        case .aaaa: 28
        case .cname: 5
        }
    }
}

public struct DNSAnswer: Sendable, Hashable, Identifiable {
    public let name: String
    public let type: String
    public let ttl: Int?
    public let data: String
    public var id: String { "\(name)|\(type)|\(data)" }
    /// The address, for A and AAAA answers.
    public var address: IPAddr? { type == "A" || type == "AAAA" ? IPAddr(data) : nil }
}

public struct DNSResult: Sendable, Hashable {
    public let domain: String
    public let type: DNSRecordType
    public let server: DNSServer
    public let answers: [DNSAnswer]
    /// NOERROR, NXDOMAIN, SERVFAIL…
    public let status: String
    public let duration: TimeInterval
}

/// DNS messages (RFC 1035) for DoH and UDP queries.
enum DNSMessage {
    static func query(_ name: String, type: DNSRecordType, id: UInt16) throws -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count < 64, label.allSatisfy(\.isASCII) else {
                throw EditorError("域名格式不正确，或含有暂不支持的非英文字符。")
            }
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes.append(0)
        bytes += [UInt8(type.code >> 8), UInt8(type.code & 0xff), 0, 1]
        return bytes
    }

    static let statuses = ["NOERROR", "FORMERR", "SERVFAIL", "NXDOMAIN", "NOTIMP", "REFUSED"]
    static let types: [UInt16: String] = [1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 15: "MX", 16: "TXT", 28: "AAAA", 64: "SVCB", 65: "HTTPS"]

    static func parse(_ data: [UInt8], id: UInt16?) throws -> (status: String, answers: [DNSAnswer]) {
        func fail() -> EditorError { EditorError("DNS 服务器返回了无法读取的响应。") }
        guard data.count >= 12 else { throw fail() }
        if let id, UInt16(data[0]) << 8 | UInt16(data[1]) != id { throw fail() }
        let rcode = Int(data[3] & 0x0f)
        let questions = Int(data[4]) << 8 | Int(data[5]), answers = Int(data[6]) << 8 | Int(data[7])
        var position = 12

        func name(at start: Int) throws -> (String, Int) {
            var labels: [String] = [], index = start, end: Int?, jumps = 0
            while true {
                guard index < data.count else { throw fail() }
                let length = Int(data[index])
                if length == 0 { index += 1; break }
                if length & 0xc0 == 0xc0 {
                    guard index + 1 < data.count, jumps < 32 else { throw fail() }
                    if end == nil { end = index + 2 }
                    index = (length & 0x3f) << 8 | Int(data[index + 1])
                    jumps += 1
                    continue
                }
                guard index + 1 + length <= data.count else { throw fail() }
                labels.append(String(decoding: data[(index + 1)..<(index + 1 + length)], as: UTF8.self))
                index += 1 + length
            }
            return (labels.joined(separator: "."), end ?? index)
        }

        for _ in 0..<questions { position = try name(at: position).1 + 4 }
        var result: [DNSAnswer] = []
        for _ in 0..<answers {
            let (owner, afterName) = try name(at: position)
            guard afterName + 10 <= data.count else { throw fail() }
            let type = UInt16(data[afterName]) << 8 | UInt16(data[afterName + 1])
            let ttl = data[(afterName + 4)..<(afterName + 8)].reduce(0) { $0 << 8 | Int($1) }
            let length = Int(data[afterName + 8]) << 8 | Int(data[afterName + 9])
            let rdata = afterName + 10
            guard rdata + length <= data.count else { throw fail() }
            let value: String
            switch type {
            case 1 where length == 4, 28 where length == 16: value = IPAddr(bytes: Array(data[rdata..<(rdata + length)])).description
            case 5: value = try name(at: rdata).0
            default: value = "\(length) 字节"
            }
            result.append(DNSAnswer(name: owner, type: types[type] ?? "TYPE\(type)", ttl: ttl, data: value))
            position = rdata + length
        }
        return (rcode < statuses.count ? statuses[rcode] : "RCODE \(rcode)", result)
    }
}

/// Runs DNS queries. The query goes only to the chosen server.
public struct DNSResolver: Sendable {
    let transport: AITransport

    public init(transport: AITransport = URLSessionTransport()) { self.transport = transport }

    public func lookup(_ domain: String, type: DNSRecordType, server: DNSServer) async throws -> DNSResult {
        guard let name = GeoLookup.domain(in: domain) else { throw EditorError("请输入域名，例如 www.example.com。") }
        let start = Date()
        let status: String, answers: [DNSAnswer]
        switch server {
        case .system:
            guard type != .cname else { throw EditorError("系统 DNS 只返回地址，不返回 CNAME；请选择 DoH 或 UDP 服务器。") }
            (status, answers) = try await Self.system(name, type: type)
        case .doh(let url):
            let message = try DNSMessage.query(name, type: type, id: 0)
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EditorError("DoH 地址无效。") }
            let items = components.queryItems ?? []
            components.queryItems = items + [URLQueryItem(name: "dns", value: Data(message).base64URL)]
            guard let requestURL = components.url else { throw EditorError("DoH 地址无效。") }
            var request = URLRequest(url: requestURL, timeoutInterval: 8)
            request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else { throw EditorError("DoH 服务器返回 HTTP \(response.statusCode)。") }
            (status, answers) = try DNSMessage.parse([UInt8](data), id: 0)
        case let .udp(host, port):
            let id = UInt16.random(in: 1...UInt16.max)
            let reply = try await Self.udp(Data(try DNSMessage.query(name, type: type, id: id)), host: host, port: port)
            (status, answers) = try DNSMessage.parse([UInt8](reply), id: id)
        }
        return DNSResult(domain: name, type: type, server: server, answers: answers, status: status, duration: Date().timeIntervalSince(start))
    }

    static func system(_ name: String, type: DNSRecordType) async throws -> (String, [DNSAnswer]) {
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_family = type == .aaaa ? AF_INET6 : AF_INET
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            let code = getaddrinfo(name, nil, &hints, &list)
            defer { if let list { freeaddrinfo(list) } }
            if code == EAI_NONAME || code == EAI_NODATA { return ("NXDOMAIN", []) }
            guard code == 0 else { throw EditorError("系统 DNS 解析失败：\(String(cString: gai_strerror(code)))") }
            var answers: [DNSAnswer] = [], node = list
            while let current = node {
                if let address = current.pointee.ai_addr {
                    var bytes: [UInt8] = []
                    if current.pointee.ai_family == AF_INET {
                        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                            bytes = withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }
                        }
                    } else if current.pointee.ai_family == AF_INET6 {
                        address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                            bytes = withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                        }
                    }
                    if !bytes.isEmpty {
                        let answer = DNSAnswer(name: name, type: type.rawValue, ttl: nil, data: IPAddr(bytes: bytes).description)
                        if !answers.contains(answer) { answers.append(answer) }
                    }
                }
                node = current.pointee.ai_next
            }
            return ("NOERROR", answers)
        }.value
    }

    static func udp(_ message: Data, host: String, port: UInt16, timeout: TimeInterval = 5) async throws -> Data {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw EditorError("端口无效。") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
        let queue = DispatchQueue(label: "veer.dns-udp")
        let finish = Once<Result<Data, Error>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                finish.setHandler { result in
                    connection.cancel()
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: message, completion: .contentProcessed { error in
                            if let error { finish.fire(.failure(error)) }
                        })
                        connection.receiveMessage { data, _, _, error in
                            if let data { finish.fire(.success(data)) }
                            else { finish.fire(.failure(error ?? EditorError("DNS 服务器没有回应。"))) }
                        }
                    case .failed(let error): finish.fire(.failure(error))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish.fire(.failure(EditorError("DNS 服务器 \(timeout.formatted()) 秒内没有回应。"))) }
            }
        } onCancel: {
            finish.fire(.failure(CancellationError()))
        }
    }
}

/// Delivers the first result only, also when it arrives before the handler is set.
final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var pending: Value?
    private var handler: ((Value) -> Void)?

    func setHandler(_ handler: @escaping (Value) -> Void) {
        let early: Value? = lock.withLock {
            if fired, let pending { self.pending = nil; return pending }
            self.handler = handler
            return nil
        }
        if let early { handler(early) }
    }

    func fire(_ value: Value) {
        let handler: ((Value) -> Void)? = lock.withLock {
            guard !fired else { return nil }
            fired = true
            if self.handler == nil { pending = value }
            return self.handler
        }
        handler?(value)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
