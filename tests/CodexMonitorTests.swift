import Foundation
import Darwin
import CryptoKit

@main
struct CodexMonitorTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("GPT_TRAFFIC_LIGHT_STATE_DIR", root.path, 1)
        defer { try? FileManager.default.removeItem(at: root) }
        func event(_ name: String, session: String = "one", turn: String = "turn-1", tool: String = "Bash", command: String = "sleep 60") throws {
            try CodexMonitor.record([
                "session_id": session, "hook_event_name": name, "turn_id": turn,
                "tool_name": tool, "tool_input": ["command": command],
                "prompt": "PRIVATE_PROMPT", "last_assistant_message": "PRIVATE_REPLY",
            ], pid: getpid())
        }
        func key(_ session: String) -> String {
            SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func pending(_ session: String = "one") throws -> Int {
            let data = try Data(contentsOf: root.appendingPathComponent(key(session) + ".json"))
            return try JSONDecoder().decode(CodexSession.self, from: data).permissions.count
        }
        func expectPending(_ expected: Int, _ label: String = "") throws {
            let count = try pending()
            precondition(count == expected, "\(label): expected \(expected) pending permissions, got \(count)")
        }
        func expect(_ state: String, _ label: String, desktop: [String: String] = [:]) {
            let mapped = Dictionary(uniqueKeysWithValues: desktop.map { (key($0.key), $0.value) })
            let actual = CodexMonitor.snapshot(desktopStates: mapped).state
            precondition(actual == state, "\(label): expected \(state), got \(actual)")
        }
        expect("offline", "no events")
        try event("SessionStart")
        expect("idle", "session starts")
        try event("UserPromptSubmit")
        expect("running", "prompt starts a turn")
        try event("SessionStart")
        expect("running", "resume/compaction preserves active turn")
        try event("PermissionRequest")
        try event("UserPromptSubmit", session: "two")
        expect("running", "hook-only approval is unconfirmed, not a red light")
        expect("attention", "confirmed approval takes priority", desktop: ["one": "attention", "two": "running"])
        try event("PreToolUse", tool: "other")
        try event("PostToolUse", tool: "other")
        try expectPending(1, "unrelated tool cannot clear permission")
        try event("PermissionRequest", command: "another command")
        try event("PostToolUse")
        try expectPending(1, "parallel permission remains pending")
        expect("attention", "remaining real approval stays red", desktop: ["one": "attention"])
        expect("running", "thinking overrides stale hook approvals", desktop: ["one": "running"])
        expect("running", "approved command stays yellow before its output returns", desktop: ["one": "running"])
        try event("PostToolUse", command: "another command")
        try expectPending(0)
        expect("running", "approved tools returned")
        try event("Stop", session: "two")
        expect("running", "one finished session cannot hide another running session")
        try event("Interrupt")
        expect("idle", "interrupt clears active state")
        try event("PostToolUse")
        expect("idle", "late result cannot restart interrupted turn")
        try event("UserPromptSubmit", turn: "turn-2")
        try event("PostToolUse", turn: "turn-1")
        try event("Stop", turn: "turn-1")
        expect("running", "old turn results ignored")
        try event("Stop", turn: "turn-2")
        // PermissionRequest may add a description, while completion supplies only the command.
        try event("UserPromptSubmit", turn: "turn-3")
        try CodexMonitor.record([
            "session_id": "one", "hook_event_name": "PermissionRequest", "turn_id": "turn-3",
            "tool_name": "Bash", "tool_input": ["command": "sleep 60", "description": "PRIVATE_REASON"]
        ], pid: getpid())
        try expectPending(1)
        try event("PostToolUse", turn: "turn-3")
        try expectPending(0, "approval-only metadata must not leave stale permissions")
        expect("idle", "actual idle overrides an old running hook", desktop: ["one": "idle", "two": "idle"])
        try event("Stop", turn: "turn-3")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            precondition(!contents.contains("PRIVATE_") && !contents.contains("sleep 60"), "content leaked")
        }
        try event("SessionEnd", turn: "turn-3")
        try event("SessionEnd", session: "two")
        expect("offline", "closed sessions removed")
        let stale = CodexSession(pid: getpid(), processStart: "old-process", state: "running", permissions: [])
        try JSONEncoder().encode(stale).write(to: root.appendingPathComponent("stale.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("broken.json"))
        expect("offline", "stale PID / corrupt state cannot turn light green or yellow")
        print("Codex lifecycle, parallel sessions, permissions, interruption, stale process and privacy checks passed")
    }
}
