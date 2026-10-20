import Foundation
import Darwin

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
        func expect(_ state: String, _ label: String) {
            let actual = CodexMonitor.snapshot().state
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
        expect("attention", "red takes priority over another running session")
        try event("PreToolUse", tool: "other")
        try event("PostToolUse", tool: "other")
        expect("attention", "unrelated tool cannot clear permission")
        try event("PermissionRequest", command: "another command")
        try event("PostToolUse")
        expect("attention", "parallel approval stays red until both return")
        try event("PostToolUse", command: "another command")
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
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let contents = try String(contentsOf: file, encoding: .utf8)
            precondition(!contents.contains("PRIVATE_") && !contents.contains("sleep 60"), "content leaked")
        }
        try event("SessionEnd", turn: "turn-2")
        try event("SessionEnd", session: "two")
        expect("offline", "closed sessions removed")
        let stale = CodexSession(pid: getpid(), processStart: "old-process", state: "running", permissions: [])
        try JSONEncoder().encode(stale).write(to: root.appendingPathComponent("stale.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("broken.json"))
        expect("offline", "stale PID / corrupt state cannot turn light green or yellow")
        print("Codex lifecycle, parallel sessions, permissions, interruption, stale process and privacy checks passed")
    }
}
