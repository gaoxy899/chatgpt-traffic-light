import Foundation
import Darwin

@main
struct CodexUsageTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let result = CodexUsageClient.fetch(executable: CodexUsageClient.executable())
            var display = UsageDisplay()
            display.finish(result)
            print("Codex 剩余：\(display.summary(now: Date()))")
            if case .failure(let error) = result {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            for (id, bucket) in display.snapshot!.response.buckets {
                print("配额类别：\(id)")
                for (label, window) in bucket.windows {
                    print("\(label) \(window.percentage(stale: false, now: Date())) \(window.resetDescription(now: Date()))")
                }
            }
            return
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func decode(_ json: String) throws -> UsageResponse {
            try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        }
        let response = try decode("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1800007200},
        "secondary":{"usedPercent":54,"windowDurationMins":10080,"resetsAt":1800086400}}}
        """)
        var display = UsageDisplay(snapshot: UsageSnapshot(response: response, updatedAt: now))
        precondition(display.summary(now: now) == "5h 72% · 周 46%", "display remaining, not used percent")
        precondition(response.buckets[0].1.primary!.progressBar == "███████░░░", "bar represents remaining quota")
        precondition(display.summary(now: now.addingTimeInterval(91)) == "5h ≈72% · 周 ≈46%")
        precondition(display.summary(now: now.addingTimeInterval(7200)).contains("≈72%"), "never infer a reset to 100%")
        display.finish(.failure(.timeout))
        precondition(display.summary(now: now) == "5h ≈72% · 周 ≈46%", "failed refresh marks old data")
        precondition(display.notice(now: now).contains("超时"))
        display.finish(.failure(.signedOut))
        precondition(display.summary(now: now) == "--", "logout clears previous quota")
        precondition(UsageDisplay().summary(now: now) == "--", "no data is not 0%")
        display.finish(.success(UsageSnapshot(response: response, updatedAt: now)))
        precondition(display.failure == nil && !display.isStale(now: now), "successful retry clears error")
        let multiple = try decode("""
        {"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{
        "other":{"limitName":"Other","primary":{"usedPercent":10,"windowDurationMins":60}},
        "codex":{"primary":{"usedPercent":92,"windowDurationMins":300}}}}
        """)
        display.finish(.success(UsageSnapshot(response: multiple, updatedAt: now)))
        precondition(display.summary(now: now) == "5h 8%!", "prefer multiple buckets and select codex")
        precondition(multiple.buckets.map { $0.0 } == ["codex", "other"])
        let other = try decode("""
        {"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":40,"windowDurationMins":60}}}}
        """)
        display.finish(.success(UsageSnapshot(response: other, updatedAt: now)))
        precondition(display.summary(now: now) == "other 1h 60%", "identify non-default quota")
        let nullable = try decode("""
        {"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null},
        "secondary":{"usedPercent":0,"windowDurationMins":45}}}
        """)
        display.finish(.success(UsageSnapshot(response: nullable, updatedAt: now)))
        precondition(display.summary(now: now) == "主 -- · 45m 100%")
        precondition(nullable.buckets[0].1.primary!.resetDescription(now: now) == "重置时间暂不可用")
        for (used, remaining) in [(105.0, 0), (-5.0, 100), (99.5, 0)] {
            let window = UsageWindow(usedPercent: used, windowDurationMins: 2880, resetsAt: now.timeIntervalSince1970)
            precondition(window.remaining == remaining)
            precondition(window.label(fallback: "主") == "2天")
            precondition(window.resetDescription(now: now).contains("等待重新查询"))
            precondition(window.percentage(stale: false, now: now).hasPrefix("≈"))
        }
        precondition(UsageWindow(usedPercent: nil, windowDurationMins: -1, resetsAt: nil).label(fallback: "次") == "次")
        precondition(UsageWindow(usedPercent: .infinity, windowDurationMins: nil, resetsAt: nil).remaining == nil)
        precondition(response.buckets[0].1.primary!.resetDescription(now: now).contains("重置"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("traffic-light-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_codex_usage.py")
        let fake = root.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: fixture, to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let pidFile = root.appendingPathComponent("pid")
        setenv("TRAFFIC_LIGHT_TEST_PID", pidFile.path, 1)
        defer {
            unsetenv("TRAFFIC_LIGHT_TEST_PID")
            unsetenv("TRAFFIC_LIGHT_TEST_MODE")
        }
        for mode in ["normal", "error", "signedOut", "apiKey", "exit", "malformed", "timeout"] {
            setenv("TRAFFIC_LIGHT_TEST_MODE", mode, 1)
            let result = CodexUsageClient.fetch(executable: fake, timeout: mode == "timeout" ? 0.2 : 5)
            switch (mode, result) {
            case ("normal", .success(let snapshot)):
                display.finish(.success(snapshot))
                precondition(display.summary(now: Date()) == "5h 72% · 周 46%")
            case ("signedOut", .failure(.signedOut)), ("apiKey", .failure(.unsupportedAuth)),
                 ("timeout", .failure(.timeout)), ("error", .failure(.queryFailed)),
                 ("exit", .failure(.queryFailed)), ("malformed", .failure(.invalidResponse)): break
            default: preconditionFailure("Unexpected RPC result for \(mode): \(result)")
            }
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
            precondition(kill(pid, 0) != 0 && errno == ESRCH, "query must not leak a child process")
        }
        if case .failure(.missingCLI) = CodexUsageClient.fetch(executable: nil) {} else { preconditionFailure() }
        print("Quota parsing, remaining percentages, stale/reset states, buckets, RPC handshake, errors, timeout and process cleanup checks passed")
    }
}
