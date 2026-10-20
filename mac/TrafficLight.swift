import AppKit
import Foundation
import Darwin

private let portNumber: UInt16 = 18765
private let sharedKey = "__TOKEN__"

final class StatusApp: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var detail: NSMenuItem!
    private var codexDetail: NSMenuItem!
    private var lastUpdate = Date.distantPast
    private var state = "offline"
    private var source = "未连接 Chrome"
    private var serverSocket: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        codexDetail = NSMenuItem(title: "等待 Codex 连接", action: nil, keyEquivalent: "")
        menu.addItem(codexDetail)
        detail = NSMenuItem(title: "等待 Chrome 扩展连接", action: nil, keyEquivalent: "")
        menu.addItem(detail)
        menu.addItem(.separator())
        let codex = NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        codex.target = self
        menu.addItem(codex)
        let connect = NSMenuItem(title: "Codex 连接 / 授权说明…", action: #selector(connectCodex), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)
        let open = NSMenuItem(title: "打开 ChatGPT", action: #selector(openChatGPT), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "退出状态灯", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve() }
    }

    private func refresh() {
        let alive = Date().timeIntervalSince(lastUpdate) < 12
        let codex = CodexMonitor.snapshot()
        let states = [codex.state, alive ? state : "offline"]
        let label: String
        if states.contains("attention") { label = "🔴" }
        else if states.contains("running") { label = "🟡" }
        else if states.contains("idle") { label = "🟢" }
        else { label = "⚪" }
        item.button?.title = "\(label) GPT"
        codexDetail.title = codex.detail
        detail.title = alive ? source : "离线：未收到浏览器心跳"
        item.button?.toolTip = "\(codex.detail)\n\(detail.title)"
    }

    @objc private func openCodex() {
        launchCodex(route: "launch")
    }

    @objc private func connectCodex() {
        let alert = NSAlert()
        alert.messageText = "连接 Codex 桌面版"
        alert.informativeText = "1. 打开 Codex 设置，进入 Hooks（生命周期钩子）。\n2. 在用户配置中找到命令指向 ~/.gpt-traffic-light/codex-hook 的 8 项 hooks，审核并信任；如未显示，点击 Reload hooks。\n3. 重新打开或新建本地会话，发送一条消息。\n\nCLI 也可输入 /hooks 审核。只需信任本状态灯的命令。\n\n“打开 Codex”仅唤起应用，不会自动授权。"
        alert.addButton(withTitle: "打开 Codex 设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { launchCodex(route: "settings") }
    }

    private func launchCodex(route: String) {
        let workspace = NSWorkspace.shared
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap { $0.bundleURL }
        let registered = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
        let locations = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let candidates = running + [registered].compactMap { $0 } + locations.flatMap { directory in
            ["Codex.app", "ChatGPT.app"].map { directory.appendingPathComponent($0) }
        }
        guard let application = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.openai.codex" }) else {
            showCodexError("未找到 Codex 桌面应用。请先手动启动 Codex，或将应用安装到 /Applications 或 ~/Applications 后重试。")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Target the app explicitly: Launch Services may not have registered its URL scheme yet.
        // A bare codex:// URL does not specify a launch action.
        workspace.open([URL(string: "codex://\(route)")!], withApplicationAt: application,
                       configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showCodexError("\(application.path)\n\n\(error.localizedDescription)")
                } else if let app = app {
                    app.activate(options: [.activateAllWindows])
                } else {
                    self.showCodexError("系统未返回 Codex 应用，请尝试从 Finder 手动打开。")
                }
            }
        }
    }

    private func showCodexError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开 Codex"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openChatGPT() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func serve() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = portNumber.bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(serverSocket, 12) == 0 else {
            DispatchQueue.main.async { self.detail.title = "端口 18765 已被占用" }
            close(serverSocket)
            return
        }
        while true {
            let client = accept(serverSocket, nil, nil)
            if client < 0 { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        let maxBytes = 8192
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            guard let header = String(data: data[..<marker.lowerBound], encoding: .utf8) else { break }
            let lengthLine = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            let length = Int(lengthLine?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
            if length > 4096 { break }
            if data.count >= marker.upperBound + length { break }
        }
        var code = "400 Bad Request"
        if let marker = data.range(of: Data("\r\n\r\n".utf8)),
           let header = String(data: data[..<marker.lowerBound], encoding: .utf8),
           header.hasPrefix("POST /status "),
           header.contains("X-Status-Key: \(sharedKey)"),
           let lengthLine = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(lengthLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""),
           length > 0, length <= 4096,
           data.count >= marker.upperBound + length,
           let json = try? JSONSerialization.jsonObject(with: data.subdata(in: marker.upperBound..<(marker.upperBound + length))) as? [String: Any],
           let next = json["state"] as? String,
           ["idle", "running", "attention"].contains(next) {
            let nextSource = (json["detail"] as? String ?? "ChatGPT").prefix(100)
            DispatchQueue.main.async {
                self.state = next
                self.source = String(nextSource)
                self.lastUpdate = Date()
                self.refresh()
            }
            code = "204 No Content"
        }
        let response = "HTTP/1.1 \(code)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = response.withCString { send(fd, $0, strlen($0), 0) }
    }
}

@main
struct TrafficLightMain {
    static func main() {
        if CommandLine.arguments.contains("--codex-hook") {
            CodexMonitor.runHook()
            return
        }
        let app = NSApplication.shared
        let delegate = StatusApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
