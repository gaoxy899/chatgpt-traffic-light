import Foundation

// The helper follows the existing desktop instance; it never launches an app-server.
// All properties below are accessed on the main thread.
final class CodexDesktopStatus {
    private var process: Process?
    private var receivedAt = Date.distantPast
    private var lastLaunch = Date.distantPast
    private var connected = false
    private var latestStates = [String: String]()
    private var stopped = false
    private let scriptURL: URL?

    init(scriptURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("codex_desktop_status.py")) {
        self.scriptURL = scriptURL
    }

    var states: [String: String] {
        Date().timeIntervalSince(receivedAt) < 6 && connected ? latestStates : [:]
    }

    var detail: String {
        guard Date().timeIntervalSince(receivedAt) < 6 && connected else {
            return "Codex 授权状态：实时通道未连接，未确认的授权不亮红灯"
        }
        return "Codex 授权状态：实时连接（\(latestStates.count) 个会话）"
    }

    func startIfNeeded() {
        guard !stopped, process == nil, Date().timeIntervalSince(lastLaunch) >= 5 else { return }
        lastLaunch = Date()
        guard let script = scriptURL,
              FileManager.default.fileExists(atPath: script.path) else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-B", script.path]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardOutput = pipe
        do { try child.run() } catch { return }
        process = child
        pipe.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = pipe.fileHandleForReading
            defer { handle.closeFile() }
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                guard buffer.count <= 1_048_576 else { child.terminate(); break }
                while let end = buffer.firstIndex(of: 0x0a) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          message["version"] as? Int == 1,
                          let connected = message["connected"] as? Bool,
                          let states = message["states"] as? [String: String],
                          states.values.allSatisfy({ ["running", "attention", "idle", "offline"].contains($0) }) else { continue }
                    DispatchQueue.main.async {
                        guard let self = self, self.process === child else { return }
                        self.latestStates = states
                        self.connected = connected
                        self.receivedAt = Date()
                    }
                }
            }
            child.waitUntilExit()
            DispatchQueue.main.async {
                guard let self = self, self.process === child else { return }
                self.process = nil
                self.latestStates.removeAll()
                self.connected = false
            }
        }
    }

    func stop() {
        stopped = true
        if let child = process, child.isRunning { child.terminate() }
    }
}
