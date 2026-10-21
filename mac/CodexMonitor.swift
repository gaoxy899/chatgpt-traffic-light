import Foundation
import Darwin
import CryptoKit

// Hooks record lifecycle metadata only; prompts, tool arguments and replies are never saved.
struct CodexSession: Codable {
    var pid: Int32
    var processStart: String
    var state: String
    var turnID: String?
    var permissions: Set<String>
    var sessionID: String? = nil
}

struct CodexSnapshot {
    let state: String
    let detail: String
}

enum CodexMonitor {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["GPT_TRAFFIC_LIGHT_STATE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gpt-traffic-light/codex-sessions", isDirectory: true)
    }

    static func processStart(_ pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_stat != SZOMB else { return nil }
        let start = info.kp_proc.p_starttime
        return "\(start.tv_sec):\(start.tv_usec)"
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func record(_ input: [String: Any], pid: Int32) throws {
        guard let id = input["session_id"] as? String, !id.isEmpty,
              let event = input["hook_event_name"] as? String,
              let start = processStart(pid) else { return }
        let supported = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                         "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
        guard supported.contains(event) else { return }
        try withLock {
            let file = directory.appendingPathComponent(digest(Data(id.utf8)) + ".json")
            let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CodexSession.self, from: $0) }
            if event == "SessionEnd" {
                if previous?.pid == pid && previous?.processStart == start { try FileManager.default.removeItem(at: file) }
                return
            }
            var session = previous.flatMap { $0.pid == pid && $0.processStart == start ? $0 : nil }
                ?? CodexSession(pid: pid, processStart: start, state: "idle", permissions: [])
            session.sessionID = id
            let turn = input["turn_id"] as? String
            // Ignore delayed tool results from an older turn.
            if ["PostToolUse", "Stop", "Interrupt"].contains(event),
               let turn = turn, let current = session.turnID, turn != current { return }
            if event == "PostToolUse", session.state == "idle", session.turnID != nil { return }
            if let turn = turn { session.turnID = turn }
            let tool = input["tool_name"] as? String ?? ""
            var args = input["tool_input"] ?? NSNull()
            // Approval input may add a description which is absent from PostToolUse.
            // For shell/edit tools, match the actual command rather than approval-only metadata.
            if ["Bash", "apply_patch"].contains(tool),
               let command = (args as? [String: Any])?["command"] as? String {
                args = ["command": command]
            }
            let encoded = try JSONSerialization.data(withJSONObject: ["name": tool, "input": args], options: [.sortedKeys])
            let permissionKey = digest(encoded)
            switch event {
            case "UserPromptSubmit":
                session.state = "running"
                session.permissions.removeAll()
            case "PermissionRequest":
                session.permissions.insert(permissionKey)
                session.state = "attention"
            case "PreToolUse", "PostToolUse":
                if event == "PostToolUse" { session.permissions.remove(permissionKey) }
                session.state = session.permissions.isEmpty ? "running" : "attention"
            case "Stop", "Interrupt":
                session.state = "idle"
                session.permissions.removeAll()
            default:
                // Resuming a session or compacting context must not reset an active turn.
                break
            }
            try JSONEncoder().encode(session).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func snapshot(desktopStates: [String: String] = [:]) -> CodexSnapshot {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return CodexSnapshot(state: "offline", detail: "Codex：等待 hooks 连接（安装后请审核并信任）")
        }
        do {
            return try withLock {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                var sessions = [CodexSession]()
                var unconfirmed = 0
                for file in files where file.pathExtension == "json" {
                    let session = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(CodexSession.self, from: $0) }
                    guard var session = session, processStart(session.pid) == session.processStart else {
                        try? FileManager.default.removeItem(at: file)
                        continue
                    }
                    if let actual = desktopStates[file.deletingPathExtension().lastPathComponent],
                       ["running", "attention", "idle", "offline"].contains(actual) {
                        session.state = actual
                    } else if session.state == "attention" {
                        // Hooks cannot observe when the approval dialog is dismissed.
                        // Only a confirmed desktop waitingOnApproval status may turn the light red.
                        session.state = "running"
                        unconfirmed += 1
                    }
                    if session.state != "offline" { sessions.append(session) }
                }
                let attention = sessions.filter { $0.state == "attention" }.count
                let running = sessions.filter { $0.state == "running" }.count
                if attention > 0 {
                    return CodexSnapshot(state: "attention", detail: "Codex：\(attention) 个会话等待授权确认")
                }
                if running > 0 {
                    let note = unconfirmed > 0 ? "（\(unconfirmed) 个会话授权状态未确认）" : ""
                    return CodexSnapshot(state: "running", detail: "Codex：\(running) 个会话思考 / 执行中\(note)")
                }
                if !sessions.isEmpty {
                    return CodexSnapshot(state: "idle", detail: "Codex：空闲 / 本轮执行结束（\(sessions.count) 个会话）")
                }
                return CodexSnapshot(state: "offline", detail: "Codex：未收到有效会话事件，请打开或新建本地会话")
            }
        } catch {
            return CodexSnapshot(state: "offline", detail: "Codex：无法读取状态目录")
        }
    }

    static func runHook() {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if let input = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                try record(input, pid: getppid())
            }
        } catch {
            // Monitoring must not block, approve, reject or add context to a Codex turn.
        }
        print("{}")
    }
}
