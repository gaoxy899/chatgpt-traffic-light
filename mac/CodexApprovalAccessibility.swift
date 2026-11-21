import AppKit
import ApplicationServices
import Foundation

// Match actual decision controls. Conversation text and ordinary input fields
// are never used as evidence of an approval request.
enum CodexApprovalButtons {
    private static let allow: Set<String> = [
        "allow once", "allow", "allow this conversation", "allow this chat",
        "allow for this conversation", "allow for this session", "run once", "run command",
        "允许一次", "允许", "本次允许", "允许此对话", "允许本次对话使用", "运行一次", "运行命令",
        "允許一次", "允許", "本次允許", "允許此對話", "執行一次", "執行指令"
    ]
    private static let deny: Set<String> = ["deny", "decline", "拒绝", "拒絕"]

    static func normalized(_ label: String) -> String {
        let firstLine = label.components(separatedBy: .newlines).first ?? ""
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s*(?:[⌘⇧⌥⌃]*[↵⏎]|enter|return|esc|escape)$"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isApproval(_ labels: [String]) -> Bool {
        let controls = Set(labels.map(normalized))
        return !controls.isDisjoint(with: allow) && !controls.isDisjoint(with: deny)
    }
}

struct CodexApprovalScan {
    var connected = false
    var complete = true
    var waiting = false
}

// Only enabled button labels from Codex windows leave the AX traversal.
// Each window is checked separately, and no accessibility action is performed.
enum CodexApprovalScanner {
    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func buttonLabels(_ element: AXUIElement) -> [String] {
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
            attribute(element, $0 as CFString) as? String
        }
        // Electron can expose the accessible name as a child static-text node.
        for child in children(element) {
            guard attribute(child, kAXRoleAttribute as CFString) as? String == kAXStaticTextRole else { continue }
            if let value = attribute(child, kAXValueAttribute as CFString) as? String { labels.append(value) }
        }
        return labels
    }

    static func scan(processes: [pid_t]) -> CodexApprovalScan {
        var result = CodexApprovalScan()
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        for pid in processes {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            // This is Electron's opt-in for exposing its accessibility tree.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
                result.complete = false
                continue
            }
            result.connected = true
            for window in windows {
                if attribute(window, kAXMinimizedAttribute as CFString) as? Bool == true { continue }
                var queue = [window]
                var index = 0
                var labels = [String]()
                while index < queue.count {
                    guard index < 6000, ProcessInfo.processInfo.systemUptime < deadline else {
                        result.complete = false
                        return result
                    }
                    let element = queue[index]
                    index += 1
                    if attribute(element, "AXHidden" as CFString) as? Bool == true { continue }
                    guard let role = attribute(element, kAXRoleAttribute as CFString) as? String else {
                        result.complete = false
                        continue
                    }
                    if role == kAXButtonRole {
                        if attribute(element, kAXEnabledAttribute as CFString) as? Bool != false {
                            labels.append(contentsOf: buttonLabels(element))
                            if CodexApprovalButtons.isApproval(labels) {
                                return CodexApprovalScan(connected: true, complete: true, waiting: true)
                            }
                        }
                    } else {
                        queue.append(contentsOf: children(element))
                    }
                }
            }
        }
        return result
    }
}

// All mutable state is confined to the main queue. AX reads run on one utility
// worker at a time, so a slow Codex window cannot stall the status menu.
final class CodexApprovalAccessibility {
    private var scanning = false
    private var generation = 0
    private var latest = CodexApprovalScan()
    private var receivedAt: TimeInterval = -.infinity
    private var processes = [pid_t]()
    var onUpdate: (() -> Void)?

    var isTrusted: Bool { AXIsProcessTrusted() }

    var isWaiting: Bool {
        isTrusted && !processes.isEmpty && latest.connected && latest.complete && latest.waiting
            && ProcessInfo.processInfo.systemUptime - receivedAt < 6
    }

    var detail: String {
        guard isTrusted else { return "授权弹窗检测：请授予辅助功能权限" }
        guard !processes.isEmpty else { return "授权弹窗检测：等待 Codex 启动" }
        guard ProcessInfo.processInfo.systemUptime - receivedAt < 6, latest.connected, latest.complete else {
            return "授权弹窗检测：正在读取 Codex 窗口"
        }
        return isWaiting ? "授权弹窗检测：等待授权确认" : "授权弹窗检测：已连接"
    }

    func refresh(applications: [NSRunningApplication]) {
        let current = applications.map { $0.processIdentifier }.sorted()
        if current != processes {
            processes = current
            generation += 1
            latest = CodexApprovalScan()
            receivedAt = -.infinity
        }
        guard isTrusted, !processes.isEmpty else {
            generation += 1
            latest = CodexApprovalScan()
            receivedAt = -.infinity
            return
        }
        guard !scanning else { return }
        scanning = true
        let revision = generation
        let processes = self.processes
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scan = CodexApprovalScanner.scan(processes: processes)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                guard self.generation == revision else { return }
                self.latest = scan
                self.receivedAt = ProcessInfo.processInfo.systemUptime
                self.onUpdate?()
            }
        }
    }

    static func openSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
