import Foundation

public struct ValidationResult: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable { case passed, unavailable, failed }
    public let status: Status
    public let message: String
    public let detail: String?

    public init(status: Status, message: String, detail: String? = nil) {
        self.status = status
        self.message = message
        self.detail = detail
    }
}

public protocol ConfigValidating: Sendable {
    func validate(_ yaml: String) async -> ValidationResult
    var versionDescription: String? { get }
}

/// Runs the bundled Mihomo binary with `-t` in an isolated temporary directory.
public struct MihomoValidator: ConfigValidating {
    public let binary: URL?
    public let timeout: TimeInterval

    public init(binary: URL? = MihomoValidator.locateBinary(), timeout: TimeInterval = 20) {
        self.binary = binary
        self.timeout = timeout
    }

    public static func locateBinary() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"], fm.isExecutableFile(atPath: env) { return URL(fileURLWithPath: env) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/mihomo"), fm.isExecutableFile(atPath: bundled.path) { return bundled }
        return nil
    }

    public var versionDescription: String? {
        guard let binary, let output = try? Self.run(binary, arguments: ["-v"], input: nil, timeout: 5, directory: nil).output else { return nil }
        return output.split(separator: "\n").first.map(String.init)
    }

    public func validate(_ yaml: String) async -> ValidationResult {
        guard let binary else {
            return ValidationResult(status: .unavailable, message: "已通过结构检查；未找到内置 Mihomo 校验器，没有进行内核校验。")
        }
        let timeout = timeout
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("veer-validate-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? fm.removeItem(at: directory) }
                let file = directory.appendingPathComponent("config.yaml")
                try Data(yaml.utf8).write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let result = try Self.run(binary, arguments: ["-t", "-d", directory.path, "-f", file.path], input: nil, timeout: timeout, directory: directory)
                if result.timedOut {
                    return ValidationResult(status: .failed, message: "内核校验超过 \(Int(timeout)) 秒，可能在下载规则集或 GEO 数据。")
                }
                if result.status == 0 {
                    return ValidationResult(status: .passed, message: "已通过 Mihomo 配置测试 · 网络可达性未验证")
                }
                let detail = Self.redact(result.output, yaml: yaml, directory: directory.path)
                let hint = detail.range(of: #"rule.?provider|download|dial|i/o timeout|no such host"#, options: [.regularExpression, .caseInsensitive]) != nil
                    ? "可能是规则集下载失败。" : ""
                return ValidationResult(status: .failed, message: "Mihomo 配置测试未通过。\(hint)", detail: String(detail.suffix(1500)))
            } catch {
                return ValidationResult(status: .unavailable, message: "已通过结构检查；无法运行 Mihomo 校验器，没有进行内核校验。")
            }
        }.value
    }

    struct RunResult { let status: Int32; let output: String; let timedOut: Bool }

    static func run(_ binary: URL, arguments: [String], input: Data?, timeout: TimeInterval, directory: URL?) throws -> RunResult {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin"]
        if let directory { environment["HOME"] = directory.path; environment["TMPDIR"] = directory.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        let timedOut = process.isRunning
        if timedOut { process.terminate(); usleep(200_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return RunResult(status: process.terminationStatus, output: collected.string, timedOut: timedOut)
    }

    final class OutputBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 64 * 1024 { data.append(chunk) }
        }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    /// Hides values of secret-looking keys and the temporary path.
    static func redact(_ output: String, yaml: String, directory: String) -> String {
        var secrets: [String] = []
        let pattern = ##"(?im)^\s*-?\s*(?:password|token|secret|uuid|private-?key|public-?key|auth|authorization|psk|server|url|obfs-password|short-id)\s*:\s*['"]?([^'"#\n]{3,})"##
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)) {
                if let range = Range(match.range(at: 1), in: yaml) { secrets.append(yaml[range].trimmingCharacters(in: .whitespaces)) }
            }
        }
        var text = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        for secret in secrets.sorted(by: { $0.count > $1.count }) where secret.count >= 3 {
            text = text.replacingOccurrences(of: secret, with: "[已隐藏]")
        }
        return text.replacingOccurrences(of: directory, with: "[临时目录]").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
