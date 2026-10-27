import AppKit
import Foundation
import Darwin

private let portNumber: UInt16 = 18765
private let sharedKey = "__TOKEN__"
private let browserConfigured = sharedKey != "__" + "TOKEN__"

final class StatusApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var detail: NSMenuItem!
    private var codexDetail: NSMenuItem!
    private var desktopDetail: NSMenuItem!
    private let desktopStatus = CodexDesktopStatus()
    private let hookInstaller = CodexHookInstaller()
    private var hookStatus: NSMenuItem!
    private var configureHooksItem: NSMenuItem!
    private var removeHooksItem: NSMenuItem!
    private var configuringHooks = false
    private var hookStatusRevision = 0
    private var usageHeading: NSMenuItem!
    private var usageRefresh: NSMenuItem!
    private var usageRows = [NSMenuItem]()
    private var usage = UsageDisplay()
    private var lastUpdate = Date.distantPast
    private var state = "offline"
    private var source = "未连接 Chrome"
    private var serverSocket: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        codexDetail = NSMenuItem(title: "等待 Codex 连接", action: nil, keyEquivalent: "")
        codexDetail.isEnabled = false
        menu.addItem(codexDetail)
        desktopDetail = NSMenuItem(title: "等待 Codex 实时状态", action: nil, keyEquivalent: "")
        desktopDetail.isEnabled = false
        menu.addItem(desktopDetail)
        detail = NSMenuItem(title: "等待 Chrome 扩展连接", action: nil, keyEquivalent: "")
        detail.isEnabled = false
        if browserConfigured { menu.addItem(detail) }
        menu.addItem(.separator())
        usageHeading = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
        usageHeading.isEnabled = false
        menu.addItem(usageHeading)
        usageRefresh = NSMenuItem(title: "立即刷新用量", action: #selector(refreshUsage), keyEquivalent: "")
        usageRefresh.target = self
        menu.addItem(usageRefresh)
        menu.addItem(.separator())
        hookStatus = NSMenuItem(title: "Hooks：正在检查配置…", action: nil, keyEquivalent: "")
        hookStatus.isEnabled = false
        menu.addItem(hookStatus)
        configureHooksItem = NSMenuItem(title: "配置 / 更新 Codex hooks…", action: #selector(configureHooks), keyEquivalent: "")
        configureHooksItem.target = self
        menu.addItem(configureHooksItem)
        removeHooksItem = NSMenuItem(title: "移除本应用 hooks…", action: #selector(removeHooks), keyEquivalent: "")
        removeHooksItem.target = self
        menu.addItem(removeHooksItem)
        let codex = NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        codex.target = self
        menu.addItem(codex)
        let connect = NSMenuItem(title: "Codex 连接 / 授权说明…", action: #selector(connectCodex), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)
        let open = NSMenuItem(title: "打开 ChatGPT", action: #selector(openChatGPT), keyEquivalent: "")
        open.target = self
        if browserConfigured { menu.addItem(open) }
        let quit = NSMenuItem(title: "退出状态灯", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        refresh()
        updateUsageMenu()
        updateHookStatus()
        refreshUsage()
        let statusTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(statusTimer, forMode: .common)
        let usageTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshUsage() }
        RunLoop.main.add(usageTimer, forMode: .common)
        // A copied Codex-only app has no browser token or extension to configure.
        if browserConfigured {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve() }
        }
    }

    private func refresh() {
        let alive = Date().timeIntervalSince(lastUpdate) < 12
        desktopStatus.startIfNeeded()
        let codex = CodexMonitor.snapshot(desktopStates: desktopStatus.states)
        let states = [codex.state, alive ? state : "offline"]
        let label: String
        if states.contains("attention") { label = "🔴" }
        else if states.contains("running") { label = "🟡" }
        else if states.contains("idle") { label = "🟢" }
        else { label = "⚪" }
        let now = Date()
        item.button?.title = "\(label) GPT \(usage.summary(now: now))"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        codexDetail.title = codex.detail
        desktopDetail.title = desktopStatus.detail
        detail.title = alive ? source : "离线：未收到浏览器心跳"
        let browserDetail = browserConfigured ? "\(detail.title)\n" : ""
        item.button?.toolTip = "\(codex.detail)\n\(desktopDetail.title)\n\(browserDetail)Codex 剩余：\(usage.summary(now: now))\n\(usage.notice(now: now))"
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateUsageMenu()
        updateHookStatus()
    }

    func applicationWillTerminate(_ notification: Notification) { desktopStatus.stop() }

    @objc private func refreshUsage() {
        guard !usage.isLoading else { return }
        usage.isLoading = true
        updateUsageMenu()
        let workspace = NSWorkspace.shared
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .compactMap { $0.bundleURL }
            + [workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")].compactMap { $0 }
        let executable = CodexUsageClient.executable(applicationURLs: apps)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = CodexUsageClient.fetch(executable: executable)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.usage.finish(result)
                self.refresh()
                self.updateUsageMenu()
            }
        }
    }

    private func updateUsageMenu() {
        guard let menu = item.menu else { return }
        usageRows.forEach { menu.removeItem($0) }
        usageRows.removeAll()
        let now = Date()
        func row(_ text: String, secondary: Bool = false) {
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            if secondary {
                entry.attributedTitle = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
                ])
            }
            menu.insertItem(entry, at: menu.index(of: usageRefresh))
            usageRows.append(entry)
        }
        if let snapshot = usage.snapshot {
            for (id, bucket) in snapshot.response.buckets {
                let title = bucket.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? (id == "codex" ? "Codex" : id)
                if snapshot.response.buckets.count > 1 || id != "codex" { row(title) }
                if bucket.windows.isEmpty { row("暂无配额窗口数据") }
                for (label, window) in bucket.windows {
                    row("\(label) 剩余 \(window.percentage(stale: usage.isStale(now: now), now: now))  \(window.progressBar)")
                    row("    \(window.resetDescription(now: now))", secondary: true)
                }
            }
            if snapshot.response.buckets.isEmpty { row("暂无配额窗口数据") }
            let formatter = DateFormatter()
            formatter.dateFormat = "M月d日 HH:mm:ss"
            row("更新于 \(formatter.string(from: snapshot.updatedAt))", secondary: true)
        }
        row(usage.notice(now: now), secondary: true)
        usageRefresh.title = usage.isLoading ? "正在刷新用量…" : "立即刷新用量"
        usageRefresh.isEnabled = !usage.isLoading
    }

    @objc private func openCodex() {
        launchCodex(route: "launch")
    }

    private func updateHookStatus() {
        guard !configuringHooks else { return }
        hookStatusRevision += 1
        let revision = hookStatusRevision
        let installer = hookInstaller
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let description = installer.statusDescription()
            DispatchQueue.main.async {
                guard let self = self, !self.configuringHooks, self.hookStatusRevision == revision else { return }
                self.hookStatus.title = description
            }
        }
    }

    @objc private func configureHooks() { changeHooks(installing: true) }
    @objc private func removeHooks() { changeHooks(installing: false) }

    private func changeHooks(installing: Bool) {
        guard !configuringHooks else { return }
        configuringHooks = true
        hookStatusRevision += 1
        configureHooksItem.isEnabled = false
        removeHooksItem.isEnabled = false
        hookStatus.title = installing ? "Hooks：正在配置…" : "Hooks：正在移除…"
        let installer = hookInstaller
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try installing ? installer.install() : installer.remove() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.configuringHooks = false
                self.configureHooksItem.isEnabled = true
                self.removeHooksItem.isEnabled = true
                self.updateHookStatus()
                self.refresh()
                switch result {
                case .success(let change):
                    let alert = NSAlert()
                    alert.messageText = installing ? "Codex hooks 已配置" : "已移除本应用 hooks"
                    var message = installing
                        ? "已准备好 \(CodexHookInstaller.events.count) 项 hooks。\n\n接下来请打开 Codex 设置 → Hooks，找到命令指向以下程序的 hooks，点击 Reload hooks 后审核并信任：\n\(installer.binaryURL.path)\n\n然后重新打开或新建本地会话，发送一条消息。CLI 中也可输入 /hooks 审核。"
                        : "其他 hooks 已保留。请在 Codex 的 Hooks 页面点击 Reload hooks。"
                    if let backup = change.backupURL { message += "\n\n原配置已备份：\n\(backup.path)" }
                    alert.informativeText = message
                    alert.addButton(withTitle: "打开 Codex 设置")
                    alert.addButton(withTitle: "完成")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { self.launchCodex(route: "settings") }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = installing ? "无法配置 Codex hooks" : "无法移除 Codex hooks"
                    alert.informativeText = "\(error.localizedDescription)\n\n配置文件：\(installer.configurationURL.path)"
                    alert.addButton(withTitle: "确定")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func connectCodex() {
        let alert = NSAlert()
        alert.messageText = "连接 Codex 桌面版"
        alert.informativeText = "1. 先点击状态灯菜单的“配置 / 更新 Codex hooks…”。\n2. 打开 Codex 设置，进入 Hooks（生命周期钩子），点击 Reload hooks。\n3. 找到命令指向 \(hookInstaller.binaryURL.path) 的 \(CodexHookInstaller.events.count) 项 hooks，审核并信任。\n4. 重新打开或新建本地会话，发送一条消息。\n\nCLI 也可输入 /hooks 审核。只需信任本状态灯的命令。\n\n菜单的“已配置”不代表 Codex 已信任；信任需在 Codex 中完成。"
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
        if CommandLine.arguments.contains("--remove-codex-hooks") {
            do {
                _ = try CodexHookInstaller().remove()
                print("已移除本应用 hooks，其他 hooks 已保留。")
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = StatusApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
