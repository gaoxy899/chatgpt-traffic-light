import Foundation
import Darwin
import CryptoKit
import CoreFoundation

private func desktopNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

// JSON booleans and fractional numbers must not be accepted as revisions/array indices.
private func desktopInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
    return number.intValue
}

struct DesktopRuntimeStatus {
    var type: String?
    var activeFlags: [String]?

    init?(_ value: Any?) {
        guard let fields = value as? [String: Any] else { return nil }
        type = fields["type"] as? String
        activeFlags = fields["activeFlags"] as? [String]
    }

    var trafficState: String? {
        switch type {
        case "active":
            guard let flags = activeFlags else { return nil }
            return flags.contains("waitingOnApproval") ? "attention" : "running"
        case "idle": return "idle"
        case "notLoaded", "systemError": return "offline"
        default: return nil
        }
    }
}

// Retain only runtime status; conversation text, tool input and titles are discarded.
struct DesktopStatusStream {
    let owner: String
    let subscribedAt: TimeInterval
    private(set) var revision: Int?
    private(set) var status: DesktopRuntimeStatus?

    init(owner: String, now: TimeInterval = desktopNow()) {
        self.owner = owner
        subscribedAt = now
    }

    mutating func accept(_ message: [String: Any], clientID: String) -> Bool {
        guard message["sourceClientId"] as? String == owner else { return true }
        if let targets = message["targetClientIds"] {
            guard let targets = targets as? [String] else { return invalidate() }
            if !targets.contains(clientID) { return true }
        }
        guard desktopInteger(message["version"]) == 11,
              let params = message["params"] as? [String: Any],
              let change = params["change"] as? [String: Any],
              let nextRevision = desktopInteger(change["revision"]) else { return invalidate() }
        if let revision = revision, nextRevision <= revision { return true }
        switch change["type"] as? String {
        case "snapshot":
            status = DesktopRuntimeStatus((change["conversationState"] as? [String: Any])?["threadRuntimeStatus"])
        case "patches":
            guard let revision = revision, desktopInteger(change["baseRevision"]) == revision,
                  let patches = change["patches"] as? [[String: Any]] else { return invalidate() }
            for patch in patches {
                guard apply(patch) else { return invalidate() }
            }
        default: return invalidate()
        }
        guard status?.trafficState != nil else { return invalidate() }
        revision = nextRevision
        return true
    }

    private mutating func invalidate() -> Bool {
        status = nil
        return false
    }

    private mutating func apply(_ patch: [String: Any]) -> Bool {
        guard let path = patch["path"] as? [Any], let op = patch["op"] as? String else { return false }
        if path.isEmpty {
            guard ["add", "replace"].contains(op) else { return false }
            status = DesktopRuntimeStatus((patch["value"] as? [String: Any])?["threadRuntimeStatus"])
            return true
        }
        guard path.first as? String == "threadRuntimeStatus" else { return true }
        guard ["add", "remove", "replace"].contains(op) else { return false }
        if path.count == 1 {
            status = op == "remove" ? nil : DesktopRuntimeStatus(patch["value"])
            return true
        }
        guard var current = status, let field = path[1] as? String else { return false }
        if path.count == 2 && field == "type" {
            guard op == "remove" || patch["value"] is String else { return false }
            current.type = op == "remove" ? nil : patch["value"] as? String
        } else if path.count == 2 && field == "activeFlags" {
            guard op == "remove" || patch["value"] is [String] else { return false }
            current.activeFlags = op == "remove" ? nil : patch["value"] as? [String]
        } else if path.count == 3 && field == "activeFlags" {
            guard var flags = current.activeFlags, let index = desktopInteger(path[2]) else { return false }
            if op == "add" {
                guard index <= flags.count, let value = patch["value"] as? String else { return false }
                flags.insert(value, at: index)
            } else {
                guard index < flags.count else { return false }
                if op == "remove" { flags.remove(at: index) }
                else {
                    guard let value = patch["value"] as? String else { return false }
                    flags[index] = value
                }
            }
            current.activeFlags = flags
        } else { return false }
        status = current
        return true
    }
}

enum DesktopIPCError: Error { case cancelled, disconnected, invalidFrame, invalidEndpoint, timeout, requestTimeout }

protocol DesktopIPCTransport: AnyObject {
    var isConnected: Bool { get }
    var isCancelled: Bool { get }
    func connect(to path: URL) throws
    func send(_ message: [String: Any]) throws
    func read(timeout: TimeInterval) throws -> [String: Any]?
    func close()
    func cancel()
}

// Only the worker uses the descriptor. Cancellation may shutdown it, but close stays
// on the worker so another thread can never accidentally use a recycled descriptor.
final class DesktopSocketTransport: DesktopIPCTransport {
    static let maxFrame = 16 * 1024 * 1024
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    private var buffer = Data()

    init() {}
    init(connectedDescriptor: Int32) throws {
        descriptor = connectedDescriptor
        try configure(connectedDescriptor)
    }
    deinit { close() }

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return descriptor >= 0 }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func configure(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw DesktopIPCError.disconnected }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    func connect(to path: URL) throws {
        // Reject endpoints writable by other users and symlinks before connecting.
        for (url, kind) in [(path.deletingLastPathComponent(), mode_t(S_IFDIR)), (path, mode_t(S_IFSOCK))] {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0,
                  info.st_mode & mode_t(S_IFMT) == kind else { throw DesktopIPCError.invalidEndpoint }
        }
        var address = sockaddr_un()
        let bytes = path.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw DesktopIPCError.invalidEndpoint }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopIPCError.disconnected }
        lock.lock()
        if cancelled { lock.unlock(); Darwin.close(fd); throw DesktopIPCError.cancelled }
        descriptor = fd
        lock.unlock()
        do {
            try configure(fd)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS else { throw DesktopIPCError.disconnected }
                guard try wait(fd, events: Int16(POLLOUT), until: desktopNow() + 1) else { throw DesktopIPCError.timeout }
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                    throw DesktopIPCError.disconnected
                }
            }
            buffer.removeAll(keepingCapacity: false)
        } catch { close(); throw error }
    }

    private func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws -> Bool {
        while !isCancelled {
            let remaining = deadline - desktopNow()
            if remaining <= 0 { return false }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&entry, 1, Int32(min(100, max(1, remaining * 1000))))
            if result > 0 { return true }
            if result < 0 && errno != EINTR { throw DesktopIPCError.disconnected }
        }
        throw DesktopIPCError.cancelled
    }

    func send(_ message: [String: Any]) throws {
        let raw = try JSONSerialization.data(withJSONObject: message)
        guard !raw.isEmpty, raw.count <= Self.maxFrame else { throw DesktopIPCError.invalidFrame }
        let length = UInt32(raw.count)
        var frame = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
        frame.append(raw)
        let deadline = desktopNow() + 1
        var offset = 0
        while offset < frame.count {
            guard try wait(descriptor, events: Int16(POLLOUT), until: deadline) else { throw DesktopIPCError.timeout }
            let count = frame.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            else { throw DesktopIPCError.disconnected }
        }
    }

    func read(timeout: TimeInterval = 0.2) throws -> [String: Any]? {
        let deadline = desktopNow() + timeout
        while !isCancelled {
            if buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                guard length > 0, length <= Self.maxFrame else { throw DesktopIPCError.invalidFrame }
                if buffer.count >= 4 + Int(length) {
                    let raw = Data(buffer.dropFirst(4).prefix(Int(length)))
                    buffer = Data(buffer.dropFirst(4 + Int(length)))
                    guard let message = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                        throw DesktopIPCError.invalidFrame
                    }
                    return message
                }
            }
            guard try wait(descriptor, events: Int16(POLLIN), until: deadline) else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count > 0 { buffer.append(contentsOf: chunk.prefix(count)) }
            else if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            else { throw DesktopIPCError.disconnected }
        }
        throw DesktopIPCError.cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        buffer.removeAll(keepingCapacity: false)
    }
}

final class DesktopStatusObserver {
    private let socketURL: URL
    private let directory: URL
    private let transport: DesktopIPCTransport
    private let now: () -> TimeInterval
    private let onUpdate: ([String: String]) -> Void
    private var clientID = "initializing-client"
    private(set) var streams = [String: DesktopStatusStream]()
    private var wanted = [String: String]()
    private var retryAfter = [String: TimeInterval]()
    private var lastStates = [String: String]()
    private var emittedAt: TimeInterval = -.infinity

    init(socketURL: URL, directory: URL, transport: DesktopIPCTransport = DesktopSocketTransport(),
         now: @escaping () -> TimeInterval = desktopNow, onUpdate: @escaping ([String: String]) -> Void) {
        self.socketURL = socketURL
        self.directory = directory
        self.transport = transport
        self.now = now
        self.onUpdate = onUpdate
    }

    func cancel() { transport.cancel() }

    func run() {
        defer { transport.close() }
        var refreshAt: TimeInterval = 0
        while !transport.isCancelled {
            do {
                if !transport.isConnected {
                    try transport.connect(to: socketURL)
                    clientID = "initializing-client"
                    let result = try request("initialize", params: ["clientType": "gpt-traffic-light"])
                    guard result["resultType"] as? String == "success",
                          let fields = result["result"] as? [String: Any], let id = fields["clientId"] as? String else {
                        throw DesktopIPCError.invalidFrame
                    }
                    clientID = id
                    refreshAt = 0
                }
                if now() >= refreshAt {
                    try synchronize()
                    refreshAt = now() + 2
                }
                if let message = try transport.read(timeout: 0.2) { try handle(message) }
                publish()
            } catch {
                transport.close()
                streams.removeAll()
                publish()
                let retryAt = now() + 1
                while !transport.isCancelled && now() < retryAt { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
    }

    private func request(_ method: String, params: [String: Any], version: Int = 0) throws -> [String: Any] {
        let requestID = UUID().uuidString
        try transport.send(["type": "request", "requestId": requestID, "sourceClientId": clientID,
                            "method": method, "params": params, "version": version, "timeoutMs": 1000])
        let deadline = now() + 1.5
        while now() < deadline && !transport.isCancelled {
            if let message = try transport.read(timeout: min(0.2, deadline - now())) {
                if message["type"] as? String == "response", message["requestId"] as? String == requestID { return message }
                try handle(message)
            }
            publish()
        }
        if transport.isCancelled { throw DesktopIPCError.cancelled }
        throw DesktopIPCError.requestTimeout
    }

    private func follow(_ thread: String, owner: String, following: Bool) throws {
        try transport.send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                            "sourceClientId": clientID, "targetClientIds": [owner],
                            "params": ["hostId": "local", "conversationId": thread, "following": following]])
    }

    func handle(_ message: [String: Any]) throws {
        if message["type"] as? String == "client-discovery-request", let id = message["requestId"] as? String {
            // The observer cannot execute commands or claim ownership of any thread.
            try transport.send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
        guard message["type"] as? String == "broadcast", let params = message["params"] as? [String: Any] else { return }
        switch message["method"] as? String {
        case "thread-stream-state-changed" where params["hostId"] as? String == "local":
            guard let thread = params["conversationId"] as? String, var stream = streams[thread] else { return }
            if stream.accept(message, clientID: clientID) { streams[thread] = stream }
            else {
                streams.removeValue(forKey: thread)
                retryAfter[thread] = now() + 30
                try follow(thread, owner: stream.owner, following: false)
            }
        case "client-status-changed" where params["status"] as? String == "disconnected":
            streams = streams.filter { $0.value.owner != params["clientId"] as? String }
        default: break
        }
    }

    func synchronize() throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var priority = [String: (active: Bool, modified: TimeInterval)]()
        wanted.removeAll()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let thread = record["sessionID"] as? String else { continue }
            let hash = SHA256.hash(data: Data(thread.utf8)).map { String(format: "%02x", $0) }.joined()
            guard hash == file.deletingPathExtension().lastPathComponent else { continue }
            wanted[thread] = hash
            let state = record["state"] as? String
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            priority[thread] = (state == "running" || state == "attention", modified?.timeIntervalSince1970 ?? 0)
        }
        retryAfter = retryAfter.filter { wanted[$0.key] != nil }
        for (thread, stream) in streams {
            let missingSnapshot = stream.status == nil && now() - stream.subscribedAt > 5
            if wanted[thread] == nil || missingSnapshot {
                streams.removeValue(forKey: thread)
                if missingSnapshot { retryAfter[thread] = now() + 30 }
                try follow(thread, owner: stream.owner, following: false)
            }
        }
        let ordered = wanted.keys.sorted {
            let a = priority[$0]!, b = priority[$1]!
            if a.active != b.active { return a.active }
            if a.modified != b.modified { return a.modified > b.modified }
            return $0 < $1
        }
        for thread in ordered where streams[thread] == nil && now() >= (retryAfter[thread] ?? 0) {
            // Discover at most one session per pass. Old sessions must not starve live status.
            retryAfter[thread] = now() + 30
            do {
                let result = try request("thread-owner-discovery", params: ["hostId": "local", "conversationId": thread], version: 1)
                if result["resultType"] as? String == "success", let owner = result["handledByClientId"] as? String {
                    streams[thread] = DesktopStatusStream(owner: owner, now: now())
                    retryAfter.removeValue(forKey: thread)
                    try follow(thread, owner: owner, following: true)
                }
            } catch DesktopIPCError.requestTimeout { /* Back off only this session. */ }
            break
        }
    }

    func publish() {
        var states = [String: String]()
        for (thread, stream) in streams {
            if let hash = wanted[thread], let state = stream.status?.trafficState { states[hash] = state }
        }
        if states != lastStates || now() - emittedAt >= 1 {
            onUpdate(states)
            lastStates = states
            emittedAt = now()
        }
    }
}

// The native worker only observes the existing desktop instance. All IPC and file
// I/O stay off the UI thread; the lock protects summaries, lifecycle and freshness.
final class CodexDesktopStatus {
    private let lock = NSLock()
    private let socketURL: URL
    private let directory: URL
    private var observer: DesktopStatusObserver?
    private var stopped = false
    private var receivedAt: TimeInterval = -.infinity
    private var latestStates = [String: String]()

    init(socketURL: URL? = nil, directory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        self.socketURL = socketURL ?? codexHome.appendingPathComponent("ipc/ipc.sock")
        self.directory = directory ?? environment["GPT_TRAFFIC_LIGHT_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".gpt-traffic-light/codex-sessions")
    }
    deinit { stop() }

    var states: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return desktopNow() - receivedAt < 6 && !stopped ? latestStates : [:]
    }

    var detail: String {
        let current = states
        return current.isEmpty ? "Codex 授权状态：实时通道未连接，未确认的授权不亮红灯"
            : "Codex 授权状态：实时连接（\(current.count) 个会话）"
    }

    func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, observer == nil else { return }
        let worker = DesktopStatusObserver(socketURL: socketURL, directory: directory) { [weak self] states in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            self.latestStates = states
            self.receivedAt = desktopNow()
        }
        observer = worker
        DispatchQueue.global(qos: .utility).async { worker.run() }
    }

    func stop() {
        lock.lock()
        stopped = true
        latestStates.removeAll()
        let worker = observer
        observer = nil
        lock.unlock()
        worker?.cancel()
    }
}
