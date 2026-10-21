import Foundation
import Darwin

struct UsageWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remaining: Int? {
        guard let used = usedPercent, used.isFinite else { return nil }
        return Int(floor(max(0, min(100, 100 - used))))
    }

    func label(fallback: String) -> String {
        guard let minutes = windowDurationMins, minutes > 0 else { return fallback }
        if minutes == 10080 { return "周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)天" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    func percentage(stale: Bool, now: Date) -> String {
        guard let remaining = remaining else { return "--" }
        let expired = resetsAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        return "\(stale || expired ? "≈" : "")\(remaining)%\(remaining <= 10 ? "!" : "")"
    }

    var progressBar: String {
        guard let remaining = remaining else { return "" }
        let filled = Int((Double(remaining) / 10).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
    }

    func resetDescription(now: Date) -> String {
        guard let seconds = resetsAt, seconds > 0 else { return "重置时间暂不可用" }
        let date = Date(timeIntervalSince1970: seconds)
        if date <= now { return "已到重置时间，等待重新查询" }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "今天 HH:mm" : "M月d日 HH:mm"
        return "\(formatter.string(from: date)) 重置"
    }
}

struct UsageBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: UsageWindow?
    let secondary: UsageWindow?

    var windows: [(String, UsageWindow)] {
        var result = [(String, UsageWindow)]()
        if let primary = primary { result.append((primary.label(fallback: "主"), primary)) }
        if let secondary = secondary { result.append((secondary.label(fallback: "次"), secondary)) }
        return result
    }
}

struct UsageResponse: Decodable {
    let rateLimits: UsageBucket?
    let rateLimitsByLimitId: [String: UsageBucket]?

    var buckets: [(String, UsageBucket)] {
        if let multiple = rateLimitsByLimitId, !multiple.isEmpty {
            return multiple.keys.sorted { a, b in
                if a == "codex" { return b != "codex" }
                if b == "codex" { return false }
                return a < b
            }.map { ($0, multiple[$0]!) }
        }
        if let legacy = rateLimits { return [(legacy.limitId ?? "codex", legacy)] }
        return []
    }
}

struct UsageSnapshot {
    let response: UsageResponse
    let updatedAt: Date
}

enum UsageError: Error, LocalizedError {
    case missingCLI, signedOut, unsupportedAuth, timeout, queryFailed, invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex CLI，请安装 Codex 或设置 GPT_TRAFFIC_LIGHT_CODEX_BIN"
        case .signedOut: return "Codex 未登录，请先在 Codex 中使用 ChatGPT 账号登录"
        case .unsupportedAuth: return "当前登录方式不支持读取 ChatGPT 套餐配额"
        case .timeout: return "用量查询超时，将自动重试"
        case .queryFailed: return "暂时无法查询用量，请检查 Codex 登录状态与网络"
        case .invalidResponse: return "Codex 返回的用量数据无法识别，请检查版本兼容性"
        }
    }

    var clearsSnapshot: Bool {
        switch self {
        case .signedOut, .unsupportedAuth: return true
        default: return false
        }
    }
}

// Main-thread state. Only the CLI query runs on a background queue.
struct UsageDisplay {
    var snapshot: UsageSnapshot?
    var failure: UsageError?
    var isLoading = false

    mutating func finish(_ result: Result<UsageSnapshot, UsageError>) {
        isLoading = false
        switch result {
        case .success(let value): snapshot = value; failure = nil
        case .failure(let error):
            failure = error
            if error.clearsSnapshot { snapshot = nil }
        }
    }

    func isStale(now: Date) -> Bool {
        failure != nil || snapshot.map { now.timeIntervalSince($0.updatedAt) > 90 } == true
    }

    func summary(now: Date) -> String {
        guard let first = snapshot?.response.buckets.first else { return "--" }
        let windows = first.1.windows
        guard !windows.isEmpty else { return "--" }
        let prefix = first.0 == "codex" ? "" : "\(first.0) "
        return prefix + windows.map { label, window in
            "\(label) \(window.percentage(stale: isStale(now: now), now: now))"
        }.joined(separator: " · ")
    }

    func notice(now: Date) -> String {
        if let failure = failure { return failure.localizedDescription }
        if snapshot == nil { return isLoading ? "正在查询 Codex 配额…" : "暂无配额数据" }
        if isStale(now: now) { return "数据已过期，等待重新查询" }
        return "百分比表示 Codex 剩余额度；! 表示剩余不超过 10%，≈ 表示旧数据"
    }
}

enum CodexUsageClient {
    static func executable(applicationURLs: [URL] = []) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["GPT_TRAFFIC_LIGHT_CODEX_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let apps = applicationURLs + ["/Applications/Codex.app", "/Applications/ChatGPT.app",
                                      home.appendingPathComponent("Applications/Codex.app").path,
                                      home.appendingPathComponent("Applications/ChatGPT.app").path]
            .map { URL(fileURLWithPath: $0) }
        let bundled = apps.flatMap { app in
            ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
                .map { app.appendingPathComponent($0) }
        }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) }
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
        return (bundled + paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") })
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func fetch(executable: URL?, timeout: TimeInterval = 15) -> Result<UsageSnapshot, UsageError> {
        guard let executable = executable else { return .failure(.missingCLI) }
        do {
            let rpc = try UsageRPC(executable: executable, timeout: timeout)
            defer { rpc.stop() }
            _ = try rpc.request(id: 0, method: "initialize", params: [
                "clientInfo": ["name": "gpt_traffic_light", "title": "GPT Traffic Light", "version": "1.1.0"]
            ])
            try rpc.send(["method": "initialized", "params": [:]])
            let account = try rpc.request(id: 1, method: "account/read", params: ["refreshToken": false])
            guard let current = account["account"] as? [String: Any] else { throw UsageError.signedOut }
            guard current["type"] as? String == "chatgpt" else { throw UsageError.unsupportedAuth }
            let result = try rpc.request(id: 2, method: "account/rateLimits/read", params: [:])
            let response = try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: result))
            return .success(UsageSnapshot(response: response, updatedAt: Date()))
        } catch let error as UsageError { return .failure(error) }
        catch is DecodingError { return .failure(.invalidResponse) }
        catch { return .failure(.queryFailed) }
    }
}

// Short-lived stdio client: no thread is started and no model request is made.
// Every read has a deadline; stderr and credential-bearing replies are never logged.
private final class UsageRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let deadline: UInt64
    private var buffer = Data()

    init(executable: URL, timeout: TimeInterval) throws {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.01, timeout) * 1_000_000_000)
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        // Avoid picking up a project's config just because the app was opened from a shell there.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
    }

    func send(_ message: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: message)
        bytes.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    func request(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params])
        while true {
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw UsageError.timeout }
            if let end = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard !line.isEmpty else { continue }
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    throw UsageError.invalidResponse
                }
                // Ignore notifications and unrelated responses, never interpret them as quota data.
                guard message["id"] as? Int == id else { continue }
                if message["error"] != nil { throw UsageError.queryFailed }
                guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                return result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw UsageError.queryFailed
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageError.queryFailed }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw UsageError.invalidResponse }
        }
    }

    func stop() {
        input.fileHandleForWriting.closeFile()
        // EOF normally shuts the server down. Escalate only for our own unresponsive child.
        for _ in 0..<25 {
            if !process.isRunning { break }
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<25 {
            if !process.isRunning { break }
            usleep(20_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        output.fileHandleForReading.closeFile()
    }
}
