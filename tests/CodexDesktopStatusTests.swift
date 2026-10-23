import Foundation
import Darwin
import CryptoKit

private func hash(_ thread: String) -> String {
    SHA256.hash(data: Data(thread.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func snapshot(_ kind: String = "active", flags: [String] = [], revision: Int = 1,
                      owner: String = "owner") -> [String: Any] {
    ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
     "sourceClientId": owner, "targetClientIds": ["observer"], "params": [
        "hostId": "local", "conversationId": "thread", "change": [
            "type": "snapshot", "revision": revision, "conversationState": [
                "threadRuntimeStatus": ["type": kind, "activeFlags": flags],
                "requests": [["command": "PRIVATE_COMMAND"]], "title": "PRIVATE_TITLE",
                "turns": [["text": "PRIVATE_TEXT"]]]]]]
}

private func patches(_ base: Int, _ revision: Int, _ values: [[String: Any]]) -> [String: Any] {
    var message = snapshot(revision: revision)
    var params = message["params"] as! [String: Any]
    params["change"] = ["type": "patches", "baseRevision": base, "revision": revision, "patches": values]
    message["params"] = params
    return message
}

private func wait(until predicate: () -> Bool, timeout: TimeInterval = 3) {
    let end = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
    precondition(predicate(), "native desktop status did not reach expected state")
}

private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("dt-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    return root
}

private func record(_ thread: String, state: String, in directory: URL) throws {
    try JSONSerialization.data(withJSONObject: ["sessionID": thread, "state": state])
        .write(to: directory.appendingPathComponent(hash(thread) + ".json"))
}

private final class FakeTransport: DesktopIPCTransport {
    var isConnected = true
    var isCancelled = false
    var time: TimeInterval = 100
    var sent = [[String: Any]]()
    var response: [String: Any]?
    var discoveries = [String]()
    var answerDiscovery = true
    var queued = [[String: Any]]()
    func connect(to path: URL) throws { isConnected = true }
    func close() { isConnected = false }
    func cancel() { isCancelled = true }
    func send(_ message: [String: Any]) throws {
        sent.append(message)
        if message["method"] as? String == "thread-owner-discovery" {
            discoveries.append((message["params"] as! [String: Any])["conversationId"] as! String)
            if answerDiscovery {
                response = ["type": "response", "requestId": message["requestId"]!,
                            "resultType": "success", "handledByClientId": "owner"]
            }
        }
    }
    func read(timeout: TimeInterval) throws -> [String: Any]? {
        if !queued.isEmpty { return queued.removeFirst() }
        if let result = response { response = nil; return result }
        time += max(0.01, timeout)
        return nil
    }
}

// A local fixture drives the complete native worker without Python or a Codex backend.
private final class FixtureServer {
    let path: URL
    private let listener: Int32
    private let lock = NSLock()
    private var pending = [[String: Any]]()
    private var methods = [String]()
    private var failure: String?
    private let done = DispatchGroup()
    private var peer: DesktopSocketTransport?
    private var stopping = false

    init(in directory: URL) throws {
        path = directory.appendingPathComponent("ipc.sock")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0, "socket() failed: \(errno)")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0, "bind() failed: \(errno)")
        precondition(chmod(path.path, 0o600) == 0)
        precondition(listen(listener, 1) == 0)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        done.enter()
        DispatchQueue.global().async { self.serve() }
    }

    func enqueue(_ message: [String: Any]) { lock.lock(); pending.append(message); lock.unlock() }
    var receivedMethods: [String] { lock.lock(); defer { lock.unlock() }; return methods }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    var hasConnection: Bool { lock.lock(); defer { lock.unlock() }; return peer != nil }
    func dropConnection() { lock.lock(); let current = peer; lock.unlock(); current?.cancel() }

    func stop() {
        lock.lock(); stopping = true; let current = peer; lock.unlock()
        current?.cancel()
        precondition(done.wait(timeout: .now() + 3) == .success, "fixture failed to stop")
        Darwin.close(listener)
    }

    private func serve() {
        defer { done.leave() }
        while true {
            lock.lock(); let stop = stopping; lock.unlock()
            if stop { return }
            let fd = accept(listener, nil, nil)
            if fd < 0 { Thread.sleep(forTimeInterval: 0.01); continue }
            do {
                let connection = try DesktopSocketTransport(connectedDescriptor: fd)
                lock.lock(); peer = connection; lock.unlock()
                defer {
                    connection.close()
                    lock.lock(); peer = nil; lock.unlock()
                }
                while !connection.isCancelled {
                    lock.lock(); let messages = pending; pending.removeAll(); lock.unlock()
                    for message in messages { try connection.send(message) }
                    guard let message = try connection.read(timeout: 0.05) else { continue }
                    let method = message["method"] as? String ?? message["type"] as? String ?? ""
                    lock.lock(); methods.append(method); lock.unlock()
                    switch method {
                    case "initialize", "thread-owner-discovery":
                        try connection.send(["type": "response", "requestId": message["requestId"]!,
                            "resultType": "success", "handledByClientId": "owner", "result": ["clientId": "observer"]])
                    case "thread-stream-following-changed":
                        if (message["params"] as? [String: Any])?["following"] as? Bool == true {
                            try connection.send(snapshot(flags: ["waitingOnApproval"]))
                        }
                    case "client-discovery-response":
                        precondition((message["response"] as? [String: Any])?["canHandle"] as? Bool == false)
                    default: preconditionFailure("unexpected mutating IPC method: \(method)")
                    }
                }
            } catch DesktopIPCError.cancelled { }
            catch DesktopIPCError.disconnected { }
            catch {
                lock.lock(); failure = String(describing: error); lock.unlock()
                return
            }
        }
    }
}

@main
struct CodexDesktopStatusTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let monitor = CodexDesktopStatus()
            monitor.startIfNeeded()
            defer { monitor.stop() }
            wait(until: { !monitor.states.isEmpty }, timeout: 15)
            print("Native live IPC connected; observed \(monitor.states.count) sessions; states: \(Set(monitor.states.values).sorted())")
            return
        }
        testStreams()
        try testFraming()
        try testDiscovery()
        try testNativeMonitor()
        print("Native desktop IPC stream, framing, discovery/backoff, reconnect and shutdown checks passed")
    }

    static func testStreams() {
        var stream = DesktopStatusStream(owner: "owner")
        precondition(stream.accept(snapshot(), clientID: "observer"))
        precondition(stream.status?.trafficState == "running")
        precondition(!String(reflecting: stream).contains("PRIVATE_"))
        precondition(stream.accept(patches(1, 2, [
            ["op": "add", "path": ["threadRuntimeStatus", "activeFlags", 0], "value": "waitingOnApproval"]
        ]), clientID: "observer"))
        precondition(stream.status?.trafficState == "attention")
        precondition(stream.accept(patches(2, 3, [
            ["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]],
            ["op": "add", "path": ["turns", 0, "text"], "value": "PRIVATE_OUTPUT"]
        ]), clientID: "observer"))
        precondition(stream.status?.trafficState == "running", "approval ended before the tool returns")
        precondition(!String(reflecting: stream).contains("PRIVATE_"))
        precondition(stream.accept(snapshot(flags: ["waitingOnUserInput"], revision: 4), clientID: "observer"))
        precondition(stream.status?.trafficState == "running")
        precondition(stream.accept(snapshot(flags: ["waitingOnApproval"], revision: 5), clientID: "observer"))
        precondition(stream.accept(snapshot(revision: 6, owner: "other"), clientID: "observer"))
        precondition(stream.accept(snapshot(revision: 4), clientID: "observer"))
        var wrongTarget = snapshot(revision: 6)
        wrongTarget["targetClientIds"] = ["other"]
        precondition(stream.accept(wrongTarget, clientID: "observer"))
        precondition(stream.status?.trafficState == "attention")
        precondition(!stream.accept(patches(3, 7, []), clientID: "observer"))
        precondition(stream.status == nil, "revision gap must invalidate a stale red light")
        precondition(stream.accept(snapshot("idle", revision: 8), clientID: "observer"))
        precondition(stream.status?.trafficState == "idle")
        var wrongVersion = snapshot(revision: 9)
        wrongVersion["version"] = 12
        precondition(!stream.accept(wrongVersion, clientID: "observer"))
        precondition(stream.status == nil)
        for value: Any in [NSNull(), [:], ["type": "active"], ["type": "active", "activeFlags": "waitingOnApproval"]] {
            precondition(DesktopRuntimeStatus(value)?.trafficState == nil)
        }
        precondition(DesktopRuntimeStatus(["type": "systemError"])?.trafficState == "offline")
        for index: Any in [-1, 1, true, 0.5] {
            var invalid = DesktopStatusStream(owner: "owner")
            precondition(invalid.accept(snapshot(), clientID: "observer"))
            precondition(!invalid.accept(patches(1, 2, [["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", index]]]), clientID: "observer"))
            precondition(invalid.status == nil)
        }
        var root = DesktopStatusStream(owner: "owner")
        precondition(root.accept(snapshot(), clientID: "observer"))
        precondition(root.accept(patches(1, 2, [["op": "replace", "path": [], "value": [
            "threadRuntimeStatus": ["type": "idle"], "title": "PRIVATE_TITLE"]]]), clientID: "observer"))
        precondition(root.status?.trafficState == "idle")
        precondition(!String(reflecting: root).contains("PRIVATE_"))
    }

    static func testFraming() throws {
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "socketpair failed: \(errno)")
        let client = try DesktopSocketTransport(connectedDescriptor: pair[0])
        let server = try DesktopSocketTransport(connectedDescriptor: pair[1])
        defer { client.close(); server.close() }
        // A known frame is split inside its UTF-8 JSON body, then two frames are coalesced.
        let raw = Data("{\"message\":\"测试\"}".utf8)
        var frame = Data([UInt8(raw.count), 0, 0, 0]); frame.append(raw)
        let first = Data(frame.prefix(6))
        precondition(first.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress!, first.count, 0) } == first.count)
        let incomplete = try client.read(timeout: 0.01)
        precondition(incomplete == nil)
        var rest = Data(frame.dropFirst(6)); rest.append(frame)
        precondition(rest.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress!, rest.count, 0) } == rest.count)
        let one = try client.read(timeout: 1), two = try client.read(timeout: 1)
        precondition(one?["message"] as? String == "测试" && two?["message"] as? String == "测试")
        try client.send(["outgoing": "测试"])
        let sent = try server.read(timeout: 1)
        precondition(sent?["outgoing"] as? String == "测试")
        let oversized = Data([1, 0, 0, 1]) // 16 MiB + 1
        _ = oversized.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress!, oversized.count, 0) }
        do { _ = try client.read(timeout: 1); preconditionFailure("oversized frame accepted") }
        catch DesktopIPCError.invalidFrame { }
        client.cancel()
        precondition(client.isCancelled)
        do { _ = try client.read(timeout: 1); preconditionFailure("cancelled read accepted") }
        catch DesktopIPCError.cancelled { }
    }

    static func testDiscovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try record("thread", state: "running", in: root)
        try record("old", state: "idle", in: root)
        try record("idle-2", state: "idle", in: root)
        try Data("[]".utf8).write(to: root.appendingPathComponent("invalid.json"))
        let fake = FakeTransport()
        var summary = [String: String]()
        let observer = DesktopStatusObserver(socketURL: root.appendingPathComponent("unused"), directory: root,
            transport: fake, now: { fake.time }, onUpdate: { summary = $0 })
        try observer.synchronize()
        precondition(fake.discoveries == ["thread"], "active sessions must be discovered first, one per pass")
        var live = snapshot()
        live["targetClientIds"] = ["initializing-client"]
        try observer.handle(live)
        observer.publish()
        precondition(summary == [hash("thread"): "running"])
        fake.answerDiscovery = false
        try observer.synchronize()
        precondition(fake.discoveries.count == 2)
        observer.publish()
        precondition(summary == [hash("thread"): "running"], "old-session timeout reset the live stream")
        try observer.synchronize()
        precondition(fake.discoveries.count == 3)
        try observer.synchronize()
        precondition(fake.discoveries.count == 3, "unresponsive sessions must back off")
        try observer.handle(["type": "client-discovery-request", "requestId": "cannot-own"])
        precondition((fake.sent.last?["response"] as? [String: Any])?["canHandle"] as? Bool == false)
        // A discovery success without a snapshot expires without starving other sessions.
        fake.answerDiscovery = true
        fake.time += 31
        try observer.synchronize()
        let missing = fake.discoveries.last!
        precondition(observer.streams[missing] != nil)
        fake.time += 6
        try observer.synchronize()
        precondition(observer.streams[missing] == nil)
        precondition(observer.streams["thread"]?.status?.trafficState == "running")
        var gap = patches(99, 100, [])
        gap["targetClientIds"] = ["initializing-client"]
        try observer.handle(gap)
        observer.publish()
        precondition(summary.isEmpty)
        precondition(!String(describing: summary).contains("PRIVATE_"))
    }

    static func testNativeMonitor() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try record("thread", state: "running", in: root)
        let server = try FixtureServer(in: root)
        defer { server.stop() }
        let monitor = CodexDesktopStatus(socketURL: server.path, directory: root)
        defer { monitor.stop() }
        monitor.startIfNeeded()
        monitor.startIfNeeded() // only one native worker may subscribe.
        wait(until: { monitor.states[hash("thread")] == "attention" })
        precondition(monitor.detail.contains("实时连接"))
        precondition(server.receivedMethods.filter { $0 == "initialize" }.count == 1)
        server.enqueue(patches(1, 2, [["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]]]))
        wait(until: { monitor.states[hash("thread")] == "running" })
        server.enqueue(snapshot("idle", revision: 3))
        wait(until: { monitor.states[hash("thread")] == "idle" })
        // A peer disconnect invalidates the old summary and reconnects on the native worker.
        server.dropConnection()
        wait(until: { monitor.states.isEmpty })
        wait(until: { monitor.states[hash("thread")] == "attention" }, timeout: 5)
        server.enqueue(["type": "client-discovery-request", "requestId": "cannot-own"])
        wait(until: { server.receivedMethods.contains("client-discovery-response") })
        server.enqueue(["type": "broadcast", "method": "client-status-changed",
                        "params": ["status": "disconnected", "clientId": "owner"]])
        wait(until: { monitor.states.isEmpty })
        monitor.stop()
        precondition(monitor.states.isEmpty && monitor.detail.contains("未连接"))
        wait(until: { !server.hasConnection })
        let calls = server.receivedMethods.count
        monitor.startIfNeeded()
        Thread.sleep(forTimeInterval: 0.2)
        precondition(monitor.states.isEmpty && server.receivedMethods.count == calls)
        precondition(server.error == nil)
        // Neither a foreign-writable socket nor a symlink can be used as the endpoint.
        let unsafe = DesktopSocketTransport()
        try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: server.path.path)
        do { try unsafe.connect(to: server.path); preconditionFailure("unsafe endpoint accepted") }
        catch DesktopIPCError.invalidEndpoint { }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: server.path.path)
        let link = root.appendingPathComponent("symlink.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: server.path)
        do { try unsafe.connect(to: link); preconditionFailure("symlink endpoint accepted") }
        catch DesktopIPCError.invalidEndpoint { }
    }
}
