import Foundation

/// Persists sessions as JSON files readable only by the user. Never stores API keys or
/// subscription URLs (sessions only record the host).
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL = SessionStore.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veer AI Editor/Sessions", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func save(_ session: Session) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var stored = session
        // A turn still running when the app quits can never finish.
        for index in stored.turns.indices where stored.turns[index].outcome == .running {
            stored.turns[index].outcome = .cancelled
            for step in stored.turns[index].steps.indices where [.running, .waiting].contains(stored.turns[index].steps[step].state) {
                stored.turns[index].steps[step].state = .cancelled
            }
        }
        let url = directory.appendingPathComponent("\(session.id.uuidString).json")
        try Self.encoder.encode(stored).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func loadAll() -> [Session] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json"))
    }

    public func deleteAll() {
        for session in loadAll() { delete(session.id) }
    }
}

/// API keys, one per AI service (`AIProvider.rawValue`).
public protocol KeyStoring: Sendable {
    func read(for provider: String) -> String?
    func save(_ key: String, for provider: String) throws
    func delete(for provider: String)
}

/// API keys in a JSON file readable only by the user (mode 0600) next to the sessions. Not the
/// Keychain: the app is ad-hoc signed, so every rebuild made macOS ask again for access.
public final class FileKeyStore: KeyStoring, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL = FileKeyStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        SessionStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("api-keys.json")
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func store(_ keys: [String: String]) throws {
        let manager = FileManager.default
        if keys.isEmpty {
            try? manager.removeItem(at: url)
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(keys)
        // Create with 0600 before writing so the key is never readable by others, even briefly.
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw EditorError("无法保存 API Key。")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
    }

    public func read(for provider: String) -> String? {
        lock.withLock { load()[provider] }
    }

    public func save(_ key: String, for provider: String) throws {
        try lock.withLock {
            var keys = load()
            keys[provider] = key
            do { try store(keys) } catch let error as EditorError { throw error } catch { throw EditorError("无法保存 API Key：\(error.localizedDescription)") }
        }
    }

    public func delete(for provider: String) {
        lock.withLock {
            var keys = load()
            keys[provider] = nil
            try? store(keys)
        }
    }
}

/// Traffic and expiry reported by a subscription's `subscription-userinfo` header.
public struct SubscriptionUsage: Codable, Sendable, Equatable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Date?

    public init(upload: Int64? = nil, download: Int64? = nil, total: Int64? = nil, expire: Date? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    public var used: Int64? {
        guard upload != nil || download != nil else { return nil }
        return (upload ?? 0) + (download ?? 0)
    }

    /// "upload=1; download=2; total=3; expire=1700000000"
    public static func parse(_ header: String?) -> SubscriptionUsage? {
        guard let header else { return nil }
        var usage = SubscriptionUsage()
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Double(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload": usage.upload = Int64(value)
            case "download": usage.download = Int64(value)
            case "total": usage.total = Int64(value)
            case "expire": if value > 0 { usage.expire = Date(timeIntervalSince1970: value) }
            default: break
            }
        }
        return usage == SubscriptionUsage() ? nil : usage
    }
}

/// What a subscription response says about itself, besides the body.
public struct SubscriptionResponse: Sendable {
    public let text: String
    /// From `profile-title` or the `Content-Disposition` filename; nil when absent.
    public let title: String?
    public let usage: SubscriptionUsage?
    public let updateIntervalHours: Int?

    public init(text: String, headers: [String: String]) {
        self.text = text
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        title = Self.title(profileTitle: lower["profile-title"], disposition: lower["content-disposition"])
        usage = SubscriptionUsage.parse(lower["subscription-userinfo"])
        updateIntervalHours = lower["profile-update-interval"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func title(profileTitle: String?, disposition: String?) -> String? {
        if var title = profileTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            if title.lowercased().hasPrefix("base64:") {
                title = ShareLinkParser.base64String(String(title.dropFirst(7))) ?? ""
            }
            if let clean = clean(title) { return clean }
        }
        guard let disposition else { return nil }
        // RFC 6266: prefer filename*=UTF-8''percent-encoded over filename="…".
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where part.lowercased().hasPrefix("filename*=") {
            var value = String(part.dropFirst("filename*=".count))
            if let quote = value.range(of: "''") { value = String(value[quote.upperBound...]) }
            if let clean = clean(value.removingPercentEncoding ?? value) { return clean }
        }
        for part in disposition.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where part.lowercased().hasPrefix("filename=") {
            let value = String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let clean = clean(value.removingPercentEncoding ?? value) { return clean }
        }
        return nil
    }

    static func clean(_ raw: String) -> String? {
        let name = raw.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(120))
    }
}

/// Downloads a subscription without following redirects (max 2 MB). HTTPS is required, except
/// that plain HTTP is allowed to loopback and private LAN hosts, where self-hosted subscription
/// managers such as Sub-Store usually run.
public struct SubscriptionFetcher: Sendable {
    public init() {}

    /// Checks the link and returns the URL to fetch; Sub-Store downloads get `target=mihomo`.
    public static func validate(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              scheme == "https" || (scheme == "http" && isLocalNetwork(host: host)), let url = components.url else {
            throw EditorError("订阅链接必须是 HTTPS 地址；HTTP 只能用于本机或局域网地址（例如自建的 Sub-Store）。")
        }
        return withSubStoreTarget(url)
    }

    /// True when the input is a single link rather than pasted content. An `http://` line counts
    /// only when it has a path or query, so a bare HTTP proxy share link stays content.
    public static func looksLikeLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains(" ") else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") { return true }
        guard lower.hasPrefix("http://"), let components = URLComponents(string: trimmed) else { return false }
        return !["", "/"].contains(components.path) || components.query != nil
    }

    /// Loopback (localhost, 127/8, ::1), RFC 1918 ranges (10/8, 172.16/12, 192.168/16) and `.local` names.
    public static func isLocalNetwork(host raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// A Sub-Store download link: `/download/<name>` or `/download/collection/<name>`, optionally
    /// behind one backend path prefix and followed by a `/<target>` segment.
    public struct SubStoreDownload: Sendable, Equatable {
        public let name: String
        public let isCollection: Bool
        /// From `?target=` or the path; nil when the link names none.
        public let target: String?
    }

    public static func subStoreDownload(_ url: URL) -> SubStoreDownload? {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard let index = segments.firstIndex(of: "download"), index <= 1 else { return nil }
        var rest = segments[(index + 1)...]
        let isCollection = rest.count >= 2 && rest.first == "collection"
        if isCollection { rest = rest.dropFirst() }
        guard let name = rest.first, !name.isEmpty, rest.count <= 2 else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "target" }?.value
        let target = query.flatMap { $0.isEmpty ? nil : $0 } ?? (rest.count == 2 ? rest.last : nil)
        return SubStoreDownload(name: name, isCollection: isCollection, target: target)
    }

    /// Adds `target=mihomo` to a Sub-Store download that names no target, so it returns Mihomo YAML.
    public static func withSubStoreTarget(_ url: URL) -> URL {
        guard let download = subStoreDownload(url), download.target == nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Edit the encoded query directly so other parameters (tokens with `%2B` etc.) keep their bytes.
        let kept = (components.percentEncodedQuery ?? "").split(separator: "&")
            .filter { !$0.lowercased().hasPrefix("target=") && $0.lowercased() != "target" }
        components.percentEncodedQuery = (kept + ["target=mihomo"]).joined(separator: "&")
        return components.url ?? url
    }

    public func fetch(_ url: URL) async throws -> SubscriptionResponse {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        // Many subscription services return Mihomo YAML only to clients that identify as clash/mihomo.
        request.setValue("Veer-AI-Editor/1.0 (compatible; clash.meta; mihomo)", forHTTPHeaderField: "User-Agent")
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) } catch {
            throw EditorError("无法下载订阅：网络错误或超时。")
        }
        guard let http = response as? HTTPURLResponse else { throw EditorError("订阅服务返回了无法识别的响应。") }
        if (300..<400).contains(http.statusCode) { throw EditorError("链接返回了重定向，Veer 不会自动跟随。请使用最终地址。") }
        guard (200..<300).contains(http.statusCode) else { throw EditorError("订阅服务返回 HTTP \(http.statusCode)。") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > ConfigDocument.maxBytes { throw EditorError("订阅内容超过 2 MB。") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw EditorError("订阅内容不是 UTF-8 文本。") }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        return SubscriptionResponse(text: text, headers: headers)
    }
}
