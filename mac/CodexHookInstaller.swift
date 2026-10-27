import Foundation
import Darwin
import CryptoKit

struct CodexHookConfigurationResult {
    let changed: Bool
    let backupURL: URL?
    let binaryUpdated: Bool
}

enum CodexHookInstallationError: LocalizedError {
    case invalidConfiguration, configurationChanged, installationBusy, missingExecutable
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "hooks.json 格式无效，未修改原配置。请修复配置后重试。"
        case .configurationChanged: return "hooks.json 在配置期间被其他程序修改，未覆盖新内容，请重试。"
        case .installationBusy: return "另一个状态灯正在配置 hooks，请稍后重试。"
        case .missingExecutable: return "无法读取应用内的 hook 程序，请重新复制完整的 GPTTrafficLight.app。"
        }
    }
}

// Installs only this app's handlers. Trust decisions remain entirely inside Codex.
struct CodexHookInstaller {
    static let marker = " # gpt-traffic-light"
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                         "PermissionRequest", "PostToolUse", "Stop", "Interrupt"]
    let configurationURL: URL
    let dataDirectory: URL
    let executableURL: URL?
    var binaryURL: URL { dataDirectory.appendingPathComponent("codex-hook") }

    init(configurationURL: URL? = nil, dataDirectory: URL? = nil, executableURL: URL? = Bundle.main.executableURL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        self.configurationURL = (configurationURL ?? codexHome.appendingPathComponent("hooks.json")).resolvingSymlinksInPath()
        self.dataDirectory = dataDirectory ?? home.appendingPathComponent(".gpt-traffic-light")
        self.executableURL = executableURL
    }

    var command: String { "exec \(Self.shellQuote(binaryURL.path)) --codex-hook\(Self.marker)" }

    // Match the previous installer's quoting so reconfiguration does not change
    // unchanged hook definitions or unnecessarily invalidate Codex's trust hashes.
    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !value.isEmpty && value.rangeOfCharacter(from: safe.inverted) == nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func statusDescription() -> String {
        do {
            let (_, original) = try readConfiguration()
            let expected = try merged(original, installing: true)
            if !NSDictionary(dictionary: original).isEqual(to: expected) { return "Hooks：未配置或需要更新" }
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { return "Hooks：程序缺失，请重新配置" }
            // Copying a new app over the old one must not leave hooks running its old executable.
            if let source = executableURL, try !sameBinary(source, binaryURL) { return "Hooks：程序有更新，请重新配置" }
            return "Hooks：已配置（信任状态请在 Codex 查看）"
        } catch { return "Hooks：配置异常，请重新配置查看原因" }
    }

    func install() throws -> CodexHookConfigurationResult { try configure(installing: true) }
    func remove() throws -> CodexHookConfigurationResult { try configure(installing: false) }

    private func configure(installing: Bool) throws -> CodexHookConfigurationResult {
        let manager = FileManager.default
        // Do not create an empty Codex configuration just to remove absent hooks.
        if !installing && !manager.fileExists(atPath: configurationURL.path) {
            if manager.fileExists(atPath: binaryURL.path) { try manager.removeItem(at: binaryURL) }
            return CodexHookConfigurationResult(changed: false, backupURL: nil, binaryUpdated: false)
        }
        // Validate before installing any executable or creating a configuration directory.
        _ = try readConfiguration()
        let parent = configurationURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = parent.appendingPathComponent(".traffic-light-hooks.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CodexHookInstallationError.installationBusy }
        defer { flock(fd, LOCK_UN) }
        let (previousData, original) = try readConfiguration()
        let updated = try merged(original, installing: installing)
        let changed = !NSDictionary(dictionary: original).isEqual(to: updated)
        // Serialize before changing anything, even if no config write will be needed.
        var encoded = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        encoded.append(0x0a)
        let binaryUpdated: Bool
        if installing {
            guard let source = executableURL, manager.isExecutableFile(atPath: source.path) else {
                throw CodexHookInstallationError.missingExecutable
            }
            try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            binaryUpdated = try installBinary(source)
        } else { binaryUpdated = false }
        var backupURL: URL?
        if changed {
            // External editors don't take our lock. Refuse to replace a file changed since reading it.
            guard try currentData() == previousData else { throw CodexHookInstallationError.configurationChanged }
            if let previousData = previousData {
                let backup = parent.appendingPathComponent(configurationURL.lastPathComponent + ".traffic-light-backup-" + UUID().uuidString)
                try previousData.write(to: backup, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                backupURL = backup
            }
            let attributes = try? manager.attributesOfItem(atPath: configurationURL.path)
            let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            try atomicWrite(encoded, to: configurationURL, mode: mode, expected: previousData)
        }
        // Unregister before deleting the executable, so a failed config write leaves working hooks.
        if !installing && manager.fileExists(atPath: binaryURL.path) { try manager.removeItem(at: binaryURL) }
        return CodexHookConfigurationResult(changed: changed, backupURL: backupURL, binaryUpdated: binaryUpdated)
    }

    private func currentData() throws -> Data? {
        do { return try Data(contentsOf: configurationURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func readConfiguration() throws -> (Data?, [String: Any]) {
        guard let data = try currentData() else { return (nil, ["hooks": [String: Any]()]) }
        guard let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CodexHookInstallationError.invalidConfiguration
        }
        // Structural validation is also required for unrelated event groups: don't destroy malformed data.
        _ = try merged(original, installing: false)
        return (data, original)
    }

    private func merged(_ original: [String: Any], installing: Bool) throws -> [String: Any] {
        var updated = original
        guard original["hooks"] == nil || original["hooks"] is [String: Any] else { throw CodexHookInstallationError.invalidConfiguration }
        var hooks = original["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { throw CodexHookInstallationError.invalidConfiguration }
            var kept = [[String: Any]]()
            var removed = false
            for var group in groups {
                guard group["hooks"] == nil || group["hooks"] is [[String: Any]] else { throw CodexHookInstallationError.invalidConfiguration }
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let remaining = handlers.filter { !(($0["command"] as? String)?.hasSuffix(Self.marker) ?? false) }
                if remaining.count == handlers.count { kept.append(group) }
                else {
                    removed = true
                    if !remaining.isEmpty { group["hooks"] = remaining; kept.append(group) }
                }
            }
            if removed {
                if kept.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = kept }
            }
        }
        if installing {
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
                hooks[event] = groups
            }
        }
        // Preserve a config without a hooks key during a no-op removal.
        if original["hooks"] != nil || installing { updated["hooks"] = hooks }
        return updated
    }

    private func sameBinary(_ source: URL, _ destination: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        return try digest(source) == digest(destination)
    }

    private func digest(_ path: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize()
    }

    private func installBinary(_ source: URL) throws -> Bool {
        if try sameBinary(source, binaryURL) {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binaryURL.path)
            return false
        }
        // Copy the signed Mach-O as a file; do not modify or re-sign it after copying.
        let staged = dataDirectory.appendingPathComponent(".codex-hook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        guard Darwin.rename(staged.path, binaryURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return true
    }

    private func atomicWrite(_ data: Data, to destination: URL, mode: Int, expected: Data?) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".traffic-light-hooks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
        guard try currentData() == expected else { throw CodexHookInstallationError.configurationChanged }
        guard Darwin.rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
