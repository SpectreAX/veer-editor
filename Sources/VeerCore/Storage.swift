import Foundation
import Security

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

/// API key storage in the login Keychain.
public protocol KeyStoring: Sendable {
    func read() -> String?
    func save(_ key: String) throws
    func delete()
}

public struct KeychainKeyStore: KeyStoring {
    let service: String
    let account: String

    public init(service: String = "com.yamax.veer.ai-editor", account: String = "ai-api-key") {
        self.service = service
        self.account = account
    }

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw EditorError("无法保存到钥匙串（错误 \(status)）。") }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

/// Imports a configuration from an HTTPS link without following redirects (max 2 MB).
public struct SubscriptionFetcher: Sendable {
    public init() {}

    public static func validate(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", components.host != nil, let url = components.url else {
            throw EditorError("订阅链接必须是 HTTPS 地址。")
        }
        return url
    }

    public func fetch(_ url: URL) async throws -> String {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Veer-AI-Editor/1.0 (Mihomo)", forHTTPHeaderField: "User-Agent")
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
        if !text.contains(":") && text.range(of: #"^[A-Za-z0-9+/=\s]+$"#, options: .regularExpression) != nil {
            throw EditorError("这是 Base64 编码的节点列表，不是 Mihomo YAML 配置。Veer 不转换这类订阅。")
        }
        return text
    }
}
