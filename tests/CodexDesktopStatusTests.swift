import Foundation
import Darwin

@main
struct CodexDesktopStatusTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture.py")
        let pidFile = root.appendingPathComponent("pid")
        try """
        import json, os, time
        from pathlib import Path
        Path('\(pidFile.path)').write_text(str(os.getpid()))
        print(json.dumps({'version': 1, 'connected': True, 'states': {'thread-hash': 'attention'}}), flush=True)
        time.sleep(30)
        """.write(to: script, atomically: true, encoding: .utf8)
        let monitor = CodexDesktopStatus(scriptURL: script)
        defer { monitor.stop() }
        func wait(until predicate: () -> Bool, timeout: TimeInterval) {
            let end = Date().addingTimeInterval(timeout)
            while !predicate() && Date() < end {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            precondition(predicate(), "desktop status helper did not reach expected state")
        }
        monitor.startIfNeeded()
        wait(until: { monitor.states["thread-hash"] == "attention" }, timeout: 3)
        precondition(monitor.detail.contains("实时连接"))
        // An alive but stuck helper cannot keep a stale red light indefinitely.
        wait(until: { monitor.states.isEmpty }, timeout: 7)
        precondition(monitor.detail.contains("未连接"))
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        monitor.stop()
        wait(until: { kill(pid, 0) != 0 && errno == ESRCH }, timeout: 3)
        monitor.startIfNeeded() // stopped monitors must not restart a child during application shutdown.
        precondition(monitor.states.isEmpty)
        print("Desktop helper startup, stale state expiry and child process shutdown checks passed")
    }
}
