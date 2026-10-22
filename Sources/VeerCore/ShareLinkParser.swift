import Foundation

/// Ordered YAML value for generated configuration; rendered by `ConfigImporter`.
public indirect enum YAMLValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case list([YAMLValue])
    case map([(String, YAMLValue)])

    public static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.list(a), .list(b)): a == b
        case let (.map(a), .map(b)): a.map(\.0) == b.map(\.0) && zip(a, b).allSatisfy { $0.1 == $1.1 }
        default: false
        }
    }

    subscript(key: String) -> YAMLValue? {
        if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Converts V2Ray-style share links to Mihomo proxy entries.
///
/// Field mapping follows Mihomo's own converter (`common/convert` in the bundled mirror), so the
/// result matches what Mihomo itself produces for a link subscription. Differences: no random
/// User-Agent header is injected into ws-opts, and `mierus`/`+realm` links are reported as
/// unsupported instead of converted.
public enum ShareLinkParser {
    public struct Result: Sendable {
        public var proxies: [[(String, YAMLValue)]]
        /// Scheme → count of links that could not be converted.
        public var skipped: [String: Int]
    }

    public static func parse(_ text: String) -> Result {
        var result = Result(proxies: [], skipped: [:])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "://") else { continue }
            let scheme = line[..<range.lowerBound].lowercased()
            guard scheme.range(of: #"^[a-z0-9+]+$"#, options: .regularExpression) != nil else { continue }
            if let proxy = convert(line: line, scheme: scheme, body: String(line[range.upperBound...])) {
                result.proxies.append(proxy)
            } else {
                result.skipped[scheme, default: 0] += 1
            }
        }
        return result
    }

    // MARK: Link pieces

    struct Link {
        var user: String?
        var password: String?
        var host: String
        var port: String?
        var path: String
        var query: [String: String]
        var name: String
    }

    /// Splits `scheme://user:pass@host:port/path?query#name` without rejecting raw Unicode names.
    static func split(_ line: String) -> Link? {
        var rest = line
        var name = ""
        if let hash = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hash)...]).removingPercentEncoding ?? String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        guard let schemeEnd = rest.range(of: "://") else { return nil }
        rest = String(rest[schemeEnd.upperBound...])
        var query: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
                if query[key] == nil { query[key] = value }
            }
            rest = String(rest[..<mark])
        }
        var path = ""
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = String(rest[..<slash])
        }
        var user: String?, password: String?
        if let at = rest.lastIndex(of: "@") {
            let info = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            if let colon = info.firstIndex(of: ":") {
                user = String(info[..<colon]).removingPercentEncoding
                password = String(info[info.index(after: colon)...]).removingPercentEncoding
            } else {
                user = info.removingPercentEncoding
            }
        }
        var host = rest, port: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = String(after.dropFirst()) }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        }
        return Link(user: user, password: password, host: host, port: port, path: path, query: query, name: name)
    }

    static func base64(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = s.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !s.isEmpty, s.range(of: #"^[A-Za-z0-9+/]+=*$"#, options: .regularExpression) != nil else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func base64String(_ text: String) -> String? { base64(text).flatMap { String(data: $0, encoding: .utf8) } }

    static func port(_ text: String?) -> YAMLValue? {
        guard let text, let value = Int(text), (1...65535).contains(value) else { return nil }
        return .int(value)
    }

    static func list(_ text: String?) -> YAMLValue? {
        guard let text, !text.isEmpty else { return nil }
        return .list(text.split(separator: ",").map { .string(String($0)) })
    }

    static func truthy(_ text: String?) -> Bool { ["1", "true", "yes"].contains(text?.lowercased() ?? "") }

    // MARK: Schemes

    static func convert(line: String, scheme: String, body: String) -> [(String, YAMLValue)]? {
        switch scheme {
        case "ss": return shadowsocks(line)
        case "ssr": return shadowsocksR(body)
        case "vmess": return vmess(line, body: body)
        case "vless": return vless(line)
        case "trojan": return trojan(line)
        case "hysteria": return hysteria(line)
        case "hysteria2", "hy2": return hysteria2(line)
        case "tuic": return tuic(line)
        case "socks", "socks5", "socks5h", "http", "https": return socks(line, scheme: scheme)
        case "anytls": return anytls(line)
        default: return nil
        }
    }

    static func shadowsocks(_ line: String) -> [(String, YAMLValue)]? {
        guard var link = split(line) else { return nil }
        if link.port == nil || link.user == nil {
            // Legacy form: ss://base64(method:password@host:port)#name
            let encoded = line.dropFirst(5).split(separator: "#").first.map(String.init) ?? ""
            let stem = encoded.split(separator: "?").first.map(String.init) ?? encoded
            guard let decoded = base64String(stem), let inner = split("ss://" + decoded) else { return nil }
            let name = link.name, query = link.query
            link = inner
            link.name = name
            link.query = query.merging(inner.query) { a, _ in a }
        }
        var cipher = link.user ?? "", password = link.password
        if password == nil {
            guard let decoded = base64String(cipher), let colon = decoded.firstIndex(of: ":") else { return nil }
            cipher = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
        }
        guard !link.host.isEmpty, let port = port(link.port), !cipher.isEmpty, let password else { return nil }
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("ss")), ("server", .string(link.host)), ("port", port),
                                            ("cipher", .string(cipher)), ("password", .string(password)), ("udp", .bool(true))]
        if link.query["udp-over-tcp"] == "true" || link.query["uot"] == "1" { proxy.append(("udp-over-tcp", .bool(true))) }
        if let plugin = link.query["plugin"], plugin.contains(";") {
            var info: [String: String] = [:]
            let parts = plugin.split(separator: ";").map(String.init)
            for part in parts.dropFirst() {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                info[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
            let pluginName = parts[0]
            if pluginName.contains("obfs") {
                proxy.append(("plugin", .string("obfs")))
                proxy.append(("plugin-opts", .map([("mode", .string(info["obfs"] ?? "")), ("host", .string(info["obfs-host"] ?? ""))])))
            } else if pluginName.contains("v2ray-plugin") {
                proxy.append(("plugin", .string("v2ray-plugin")))
                proxy.append(("plugin-opts", .map([("mode", .string(info["mode"] ?? info["obfs"] ?? "")), ("host", .string(info["host"] ?? info["obfs-host"] ?? "")),
                                                   ("path", .string(info["path"] ?? "")), ("tls", .bool(plugin.contains("tls")))])))
            }
        }
        return proxy
    }

    static func shadowsocksR(_ body: String) -> [(String, YAMLValue)]? {
        guard let decoded = base64String(body), let separator = decoded.range(of: "/?") else { return nil }
        let head = decoded[..<separator.lowerBound].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard head.count == 6, let port = port(head[1]) else { return nil }
        var query: [String: String] = [:]
        for pair in decoded[separator.upperBound...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { query[kv[0]] = base64String(kv[1]) ?? "" }
        }
        var proxy: [(String, YAMLValue)] = [("name", .string(query["remarks"] ?? "")), ("type", .string("ssr")), ("server", .string(head[0])), ("port", port),
                                            ("cipher", .string(head[3])), ("password", .string(base64String(head[5]) ?? "")),
                                            ("obfs", .string(head[4])), ("protocol", .string(head[2])), ("udp", .bool(true))]
        if let value = query["obfsparam"], !value.isEmpty { proxy.append(("obfs-param", .string(value))) }
        if let value = query["protoparam"], !value.isEmpty { proxy.append(("protocol-param", .string(value))) }
        return proxy
    }

    static func vmess(_ line: String, body: String) -> [(String, YAMLValue)]? {
        let payload = body.split(separator: "#").first.map(String.init) ?? body
        guard let data = base64(payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Xray VMessAEAD share link
            guard var proxy = vShare(line, type: "vmess") else { return nil }
            let link = split(line)
            proxy.append(("alterId", .int(0)))
            proxy.append(("cipher", .string(link?.query["encryption"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto")))
            return proxy
        }
        func text(_ key: String) -> String? {
            if let s = json[key] as? String { return s }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return nil
        }
        guard let name = json["ps"] as? String, let server = text("add"), let port = port(text("port")), let uuid = text("id") else { return nil }
        var proxy: [(String, YAMLValue)] = [("name", .string(name)), ("type", .string("vmess")), ("server", .string(server)), ("port", port),
                                            ("uuid", .string(uuid)), ("alterId", .int(Int(text("aid") ?? "0") ?? 0)), ("udp", .bool(true)),
                                            ("xudp", .bool(true))]
        let tls = (text("tls") ?? "").lowercased().hasSuffix("tls")
        proxy.append(("tls", .bool(tls)))
        proxy.append(("skip-cert-verify", .bool(false)))
        proxy.append(("cipher", .string(text("scy").flatMap { $0.isEmpty ? nil : $0 } ?? "auto")))
        if let sni = text("sni"), !sni.isEmpty { proxy.append(("servername", .string(sni))) }
        var network = (text("net") ?? "").lowercased()
        if text("type") == "http" { network = "http" } else if network == "http" { network = "h2" }
        if !network.isEmpty { proxy.append(("network", .string(network))) }
        if tls, let alpn = list(text("alpn")) { proxy.append(("alpn", alpn)) }
        let host = text("host").flatMap { $0.isEmpty ? nil : $0 }, path = text("path").flatMap { $0.isEmpty ? nil : $0 }
        switch network {
        case "http":
            proxy.append(("http-opts", .map([("path", .list([.string(path ?? "/")])), ("headers", .map(host.map { [("Host", .list([.string($0)]))] } ?? []))])))
        case "h2":
            var opts: [(String, YAMLValue)] = [("path", .string(path ?? "/"))]
            if let host { opts.append(("host", .list([.string(host)]))) }
            proxy.append(("h2-opts", .map(opts)))
        case "ws", "httpupgrade":
            proxy.append(("ws-opts", .map(wsOptions(path: path ?? "/", host: host, network: network))))
        case "grpc":
            proxy.append(("grpc-opts", .map([("grpc-service-name", .string(path ?? ""))])))
        default:
            break
        }
        return proxy
    }

    /// ws/httpupgrade options, moving `?ed=N` from the path into early-data settings like Mihomo.
    static func wsOptions(path: String, host: String?, network: String, earlyData: String? = nil, earlyHeader: String? = nil) -> [(String, YAMLValue)] {
        var opts: [(String, YAMLValue)] = []
        var cleanPath = path, early = earlyData, header = earlyHeader
        if var components = URLComponents(string: path), let items = components.queryItems {
            if let ed = items.first(where: { $0.name == "ed" })?.value { early = ed }
            if let eh = items.first(where: { $0.name == "eh" })?.value { header = eh }
            let rest = items.filter { $0.name != "ed" }
            components.queryItems = rest.isEmpty ? nil : rest
            cleanPath = components.string ?? path
        }
        opts.append(("path", .string(cleanPath)))
        opts.append(("headers", .map(host.map { [("Host", .string($0))] } ?? [])))
        if let early, let size = Int(early) {
            if network == "ws" {
                opts.append(("max-early-data", .int(size)))
                opts.append(("early-data-header-name", .string(header ?? "Sec-WebSocket-Protocol")))
            } else {
                opts.append(("v2ray-http-upgrade-fast-open", .bool(true)))
            }
        } else if let header {
            opts.append(("early-data-header-name", .string(header)))
        }
        return opts
    }

    /// Xray share-link standard shared by VLESS and VMessAEAD.
    static func vShare(_ line: String, type: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string(type)), ("server", .string(link.host)), ("port", port),
                                            ("uuid", .string(link.user ?? "")), ("udp", .bool(true))]
        let security = (q["security"] ?? "").lowercased()
        if security.hasSuffix("tls") || security == "reality" {
            proxy.append(("tls", .bool(true)))
            proxy.append(("client-fingerprint", .string(q["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome")))
            if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
            if let pcs = q["pcs"], !pcs.isEmpty { proxy.append(("fingerprint", .string(pcs))) }
        }
        if let sni = q["sni"], !sni.isEmpty { proxy.append(("servername", .string(sni))) }
        if let key = q["pbk"], !key.isEmpty { proxy.append(("reality-opts", .map([("public-key", .string(key)), ("short-id", .string(q["sid"] ?? ""))]))) }
        switch q["packetEncoding"] {
        case "none": break
        case "packet": proxy.append(("packet-addr", .bool(true)))
        default: proxy.append(("xudp", .bool(true)))
        }
        var network = (q["type"] ?? "tcp").lowercased()
        if network.isEmpty { network = "tcp" }
        if network == "tcp" && q["headerType"]?.lowercased() == "http" { network = "http" } else if network == "http" { network = "h2" }
        proxy.append(("network", .string(network)))
        let host = q["host"].flatMap { $0.isEmpty ? nil : $0 }
        switch network {
        case "http":
            var opts: [(String, YAMLValue)] = [("path", .list([.string(q["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/")]))]
            if let method = q["method"], !method.isEmpty { opts.insert(("method", .string(method)), at: 0) }
            opts.append(("headers", .map(host.map { [("Host", .list([.string($0)]))] } ?? [])))
            proxy.append(("http-opts", .map(opts)))
        case "h2":
            var opts: [(String, YAMLValue)] = [("path", .string(q["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "/"))]
            if let host { opts.append(("host", .list([.string(host)]))) }
            proxy.append(("h2-opts", .map(opts)))
        case "ws", "httpupgrade":
            guard q["ed"].map({ Int($0) != nil }) ?? true else { return nil }
            proxy.append(("ws-opts", .map(wsOptions(path: q["path"] ?? "", host: host, network: network, earlyData: q["ed"], earlyHeader: q["eh"]))))
        case "grpc":
            proxy.append(("grpc-opts", .map([("grpc-service-name", .string(q["serviceName"] ?? ""))])))
        case "xhttp":
            var opts: [(String, YAMLValue)] = []
            for key in ["path", "host", "mode"] { if let value = q[key], !value.isEmpty { opts.append((key, .string(value))) } }
            proxy.append(("xhttp-opts", .map(opts)))
        default:
            break
        }
        return proxy
    }

    static func vless(_ line: String) -> [(String, YAMLValue)]? {
        guard var proxy = vShare(line, type: "vless") else { return nil }
        let q = split(line)?.query ?? [:]
        if let flow = q["flow"], !flow.isEmpty { proxy.append(("flow", .string(flow.lowercased()))) }
        if let encryption = q["encryption"], !encryption.isEmpty { proxy.append(("encryption", .string(encryption))) }
        return proxy
    }

    static func trojan(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port), let password = link.user else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("trojan")), ("server", .string(link.host)), ("port", port),
                                            ("password", .string(password)), ("udp", .bool(true)), ("skip-cert-verify", .bool(truthy(q["allowInsecure"])))]
        if let sni = q["sni"], !sni.isEmpty { proxy.append(("sni", .string(sni))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        let network = (q["type"] ?? "").lowercased()
        if !network.isEmpty { proxy.append(("network", .string(network))) }
        if network == "ws" {
            proxy.append(("ws-opts", .map([("path", .string(q["path"] ?? "")), ("headers", .map(q["host"].flatMap { $0.isEmpty ? nil : [("Host", .string($0))] } ?? []))])))
        } else if network == "grpc" {
            proxy.append(("grpc-opts", .map([("grpc-service-name", .string(q["serviceName"] ?? ""))])))
        }
        proxy.append(("client-fingerprint", .string(q["fp"].flatMap { $0.isEmpty ? nil : $0 } ?? "chrome")))
        if let pcs = q["pcs"], !pcs.isEmpty { proxy.append(("fingerprint", .string(pcs))) }
        return proxy
    }

    static func hysteria(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("hysteria")), ("server", .string(link.host)), ("port", port)]
        if let sni = q["peer"], !sni.isEmpty { proxy.append(("sni", .string(sni))) }
        if let obfs = q["obfs"], !obfs.isEmpty { proxy.append(("obfs", .string(obfs))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let auth = q["auth"], !auth.isEmpty { proxy.append(("auth-str", .string(auth))) }
        if let proto = q["protocol"], !proto.isEmpty { proxy.append(("protocol", .string(proto))) }
        proxy.append(("up", .string(q["up"] ?? q["upmbps"] ?? "")))
        proxy.append(("down", .string(q["down"] ?? q["downmbps"] ?? "")))
        proxy.append(("skip-cert-verify", .bool(truthy(q["insecure"]))))
        return proxy
    }

    static func hysteria2(_ line: String) -> [(String, YAMLValue)]? {
        // Port hopping: host:443,20000-30000 → port 443, ports "443,20000-30000".
        var hopLine = line, ports: String?
        if let regex = try? NSRegularExpression(pattern: #"(@[^/?#]*?:)(\d+(?:[-,]\d+)+)"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 2), in: line) {
            ports = String(line[range])
            let first = ports!.split(whereSeparator: { $0 == "," || $0 == "-" }).first.map(String.init) ?? "443"
            hopLine = line.replacingCharacters(in: range, with: first)
        }
        guard let link = split(hopLine), !link.host.isEmpty else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("hysteria2")), ("server", .string(link.host)),
                                            ("port", port(link.port) ?? .int(443))]
        if let ports { proxy.append(("ports", .string(ports))) }
        var auth = link.user ?? ""
        if let pass = link.password { auth += ":" + pass }
        if !auth.isEmpty { proxy.append(("password", .string(auth))) }
        if let obfs = q["obfs"], !obfs.isEmpty {
            proxy.append(("obfs", .string(obfs)))
            proxy.append(("obfs-password", .string(q["obfs-password"] ?? "")))
        }
        if let sni = q["sni"], !sni.isEmpty { proxy.append(("sni", .string(sni))) }
        proxy.append(("skip-cert-verify", .bool(truthy(q["insecure"]))))
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let pin = q["pinSHA256"], !pin.isEmpty { proxy.append(("fingerprint", .string(pin))) }
        if let up = q["up"], !up.isEmpty { proxy.append(("up", .string(up))) }
        if let down = q["down"], !down.isEmpty { proxy.append(("down", .string(down))) }
        return proxy
    }

    static func tuic(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port), let user = link.user else { return nil }
        let q = link.query
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name)), ("type", .string("tuic")), ("server", .string(link.host)), ("port", port),
                                            ("udp", .bool(true))]
        if let password = link.password {
            proxy.append(("uuid", .string(user)))
            proxy.append(("password", .string(password)))
        } else {
            proxy.append(("token", .string(user)))
        }
        if let cc = q["congestion_control"], !cc.isEmpty { proxy.append(("congestion-controller", .string(cc))) }
        if let alpn = list(q["alpn"]) { proxy.append(("alpn", alpn)) }
        if let sni = q["sni"], !sni.isEmpty { proxy.append(("sni", .string(sni))) }
        if q["disable_sni"] == "1" { proxy.append(("disable-sni", .bool(true))) }
        if let mode = q["udp_relay_mode"], !mode.isEmpty { proxy.append(("udp-relay-mode", .string(mode))) }
        return proxy
    }

    static func socks(_ line: String, scheme: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        var username = "", password = ""
        if let user = link.user {
            let raw = link.password.map { "\(user):\($0)" } ?? (base64String(user) ?? user)
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            username = parts.first ?? ""
            password = parts.count > 1 ? parts[1] : ""
        }
        let isHTTP = scheme == "http" || scheme == "https"
        var proxy: [(String, YAMLValue)] = [("name", .string(link.name.isEmpty ? "\(link.host):\(link.port ?? "")" : link.name)),
                                            ("type", .string(isHTTP ? "http" : "socks5")), ("server", .string(link.host)), ("port", port),
                                            ("username", .string(username)), ("password", .string(password)), ("skip-cert-verify", .bool(true))]
        if scheme == "https" { proxy.append(("tls", .bool(true))) }
        return proxy
    }

    static func anytls(_ line: String) -> [(String, YAMLValue)]? {
        guard let link = split(line), !link.host.isEmpty, let port = port(link.port) else { return nil }
        let q = link.query
        let username = link.user ?? ""
        return [("name", .string(link.name.isEmpty ? "\(link.host):\(link.port ?? "")" : link.name)), ("type", .string("anytls")),
                ("server", .string(link.host)), ("port", port), ("password", .string(link.password ?? username)),
                ("sni", .string(q["sni"] ?? "")), ("fingerprint", .string(q["hpkp"] ?? "")), ("skip-cert-verify", .bool(q["insecure"] == "1")),
                ("udp", .bool(true))]
    }
}
