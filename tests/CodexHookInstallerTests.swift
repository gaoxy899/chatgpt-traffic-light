import Foundation
import Darwin

@main
struct CodexHookInstallerTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hook-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source-hook")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try testMergeAndRemove(root, source: source)
        try testInvalidConfiguration(root, source: source)
        try testEmptyAndMissing(root, source: source)
        try testNativeHook(root)
        print("Native hook install/update/remove, backup, quoting, idempotency and invalid-config preservation checks passed")
    }

    static func testMergeAndRemove(_ root: URL, source: URL) throws {
        let folder = root.appendingPathComponent("merge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("hooks.json")
        let original: [String: Any] = ["description": "existing", "trustMetadata": ["keep": true], "hooks": [
            "Stop": [["matcher": "", "hooks": [["type": "command", "command": "original"]]]],
            "PreCompact": [["hooks": [["type": "command", "command": "compact"]]]], "PostCompact": []]]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        let dataFolder = folder.appendingPathComponent("space ' quote $ dollar `backtick` $(echo INJECTED) 中文")
        let installer = CodexHookInstaller(configurationURL: path, dataDirectory: dataFolder, executableURL: source)
        precondition(installer.statusDescription().contains("未配置"))
        let first = try installer.install()
        precondition(first.changed && first.binaryUpdated)
        let backupData = try Data(contentsOf: first.backupURL!)
        precondition(backupData == originalData)
        let hooks = try contents(path)["hooks"] as! [String: [[String: Any]]]
        precondition(hooks["Stop"]?.count == 2 && hooks["PreCompact"]?.count == 1 && hooks["PostCompact"]?.isEmpty == true)
        precondition((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "original")
        let metadata = try contents(path)["trustMetadata"] as! [String: Any]
        precondition(NSDictionary(dictionary: metadata).isEqual(to: ["keep": true]))
        for event in CodexHookInstaller.events {
            let handlers = hooks[event]!.last!["hooks"] as! [[String: Any]]
            precondition(handlers.count == 1 && handlers[0]["command"] as? String == installer.command)
            precondition(handlers[0]["timeout"] as? Int == 3)
        }
        let copiedData = try Data(contentsOf: installer.binaryURL)
        let sourceData = try Data(contentsOf: source)
        precondition(copiedData == sourceData)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o640)
        precondition(installer.statusDescription().contains("已配置"))
        // Run the command with shell metacharacters in its path: they must remain literal.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", installer.command]
        let output = Pipe(); shell.standardOutput = output
        try shell.run(); shell.waitUntilExit()
        let argument = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        precondition(shell.terminationStatus == 0 && argument == "--codex-hook")
        let afterFirst = try Data(contentsOf: path)
        let again = try installer.install()
        let afterAgain = try Data(contentsOf: path)
        precondition(!again.changed && !again.binaryUpdated && again.backupURL == nil && afterFirst == afterAgain)
        // App upgrades replace only the executable when the hook definition is unchanged.
        try Data("#!/bin/sh\nprintf updated\n".utf8).write(to: source)
        precondition(installer.statusDescription().contains("更新"))
        let upgrade = try installer.install()
        precondition(!upgrade.changed && upgrade.binaryUpdated && upgrade.backupURL == nil)
        let afterUpgrade = try Data(contentsOf: path)
        precondition(afterUpgrade == afterFirst)
        let removed = try installer.remove()
        precondition(removed.changed && removed.backupURL != nil)
        let restored = try contents(path)
        precondition(NSDictionary(dictionary: restored).isEqual(to: original))
        precondition(!FileManager.default.fileExists(atPath: installer.binaryURL.path))
        let removeAgain = try installer.remove()
        precondition(!removeAgain.changed && removeAgain.backupURL == nil)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("traffic-light-backup") }
        precondition(backups.count == 2)
        // Old marker handlers can share a group with foreign handlers; preserve the latter and its metadata.
        let mixed: [String: Any] = ["hooks": ["CustomEvent": [["matcher": "keep", "hooks": [
            ["command": "old-command" + CodexHookInstaller.marker], ["command": "keep-other"]]]]]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: path)
        _ = try installer.install()
        let custom = (try contents(path)["hooks"] as! [String: [[String: Any]]])["CustomEvent"]!
        precondition(custom.count == 1 && custom[0]["matcher"] as? String == "keep")
        let handlers = custom[0]["hooks"] as! [[String: Any]]
        precondition(handlers.count == 1 && handlers[0]["command"] as? String == "keep-other")
        _ = try installer.remove()
    }

    static func testInvalidConfiguration(_ root: URL, source: URL) throws {
        let folder = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("hooks.json")
        let installer = CodexHookInstaller(configurationURL: path, dataDirectory: folder.appendingPathComponent("data"), executableURL: source)
        for raw in ["broken", "[]", "{\"hooks\":null}", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}", "{\"hooks\":{\"Stop\":[{\"hooks\":null}]}}"] {
            let data = Data(raw.utf8)
            try data.write(to: path)
            for installing in [true, false] {
                do {
                    _ = try installing ? installer.install() : installer.remove()
                    preconditionFailure("invalid configuration accepted")
                } catch CodexHookInstallationError.invalidConfiguration { }
            }
            let untouched = try Data(contentsOf: path)
            precondition(untouched == data && !FileManager.default.fileExists(atPath: installer.binaryURL.path))
        }
    }

    static func testEmptyAndMissing(_ root: URL, source: URL) throws {
        let missing = root.appendingPathComponent("missing/hooks.json")
        let installer = CodexHookInstaller(configurationURL: missing, dataDirectory: root.appendingPathComponent("new-data"), executableURL: source)
        let result = try installer.remove()
        precondition(!result.changed && !FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let first = try installer.install()
        precondition(first.changed && first.backupURL == nil && FileManager.default.isExecutableFile(atPath: installer.binaryURL.path))
        _ = try installer.remove()
        let empty: [String: Any] = ["description": "without hooks"]
        try JSONSerialization.data(withJSONObject: empty).write(to: missing)
        let noChange = try installer.remove()
        let afterRemoval = try contents(missing)
        precondition(!noChange.changed && NSDictionary(dictionary: afterRemoval).isEqual(to: empty))
        let noSource = CodexHookInstaller(configurationURL: missing, dataDirectory: installer.dataDirectory, executableURL: nil)
        do { _ = try noSource.install(); preconditionFailure("missing executable accepted") }
        catch CodexHookInstallationError.missingExecutable { }
        let afterFailure = try contents(missing)
        precondition(NSDictionary(dictionary: afterFailure).isEqual(to: empty))
    }

    static func testNativeHook(_ root: URL) throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["HOOK_TEST_APP"] else { return }
        let folder = root.appendingPathComponent("native")
        let installer = CodexHookInstaller(configurationURL: folder.appendingPathComponent("hooks.json"),
            dataDirectory: folder.appendingPathComponent("data"), executableURL: URL(fileURLWithPath: sourcePath))
        _ = try installer.install()
        // End-to-end: the copied app executable is also the native lifecycle hook.
        let hook = Process()
        hook.executableURL = installer.binaryURL
        hook.arguments = ["--codex-hook"]
        var environment = ProcessInfo.processInfo.environment
        let state = folder.appendingPathComponent("sessions")
        environment["GPT_TRAFFIC_LIGHT_STATE_DIR"] = state.path
        hook.environment = environment
        let input = Pipe(), output = Pipe()
        hook.standardInput = input; hook.standardOutput = output
        try hook.run()
        let event: [String: Any] = ["session_id": "installer-test", "hook_event_name": "UserPromptSubmit", "prompt": "PRIVATE_PROMPT"]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: event))
        try input.fileHandleForWriting.close()
        hook.waitUntilExit()
        precondition(hook.terminationStatus == 0)
        let files = try FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        precondition(files.count == 1)
        let data = try Data(contentsOf: files[0])
        let session = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(session["state"] as? String == "running")
        precondition(!String(data: data, encoding: .utf8)!.contains("PRIVATE_PROMPT"))
        _ = try installer.remove()
        print("Copied app executable processed a native Codex hook successfully")
    }

    static func contents(_ path: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }
}
