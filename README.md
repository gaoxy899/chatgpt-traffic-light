# ChatGPT / Codex Mac Traffic Light

macOS 菜单栏显示 Codex 桌面版本地会话和 ChatGPT 网页状态：🟡 执行中、🔴 等待授权 / 工具返回、🟢 空闲 / 本轮结束、⚪ 未连接。

同时显示 Codex **剩余额度**，例如 `🟡 GPT 5h 72% · 周 46%`。窗口名称按服务端返回的实际时长生成；这里的百分比属于 Codex 配额，不代表 ChatGPT 网页聊天额度。

## 安装

系统要求：macOS 12+、Apple Command Line Tools、Python 3。Codex 需要支持生命周期 hooks 的版本；只监测 Codex 时不需要 Chrome 扩展。

```bash
xcode-select --install   # 如果已经安装可跳过
cd /Users/gaoxy/dev/chatgpt-traffic-light
bash install.sh
open ~/Applications/GPTTrafficLight.app
```

升级时先从菜单退出旧的状态灯，再重新安装和启动。

### Codex 桌面版

安装器会向 `${CODEX_HOME:-~/.codex}/hooks.json` 合并本应用的 hooks，保留原有 hooks，并在修改前生成 `.traffic-light-backup-时间戳` 备份。不会修改已有 hooks 的信任设置。

1. 点击状态灯菜单的“Codex 连接 / 授权说明…”→“打开 Codex 设置”，进入 Hooks（生命周期钩子）。在用户配置中找到命令指向 `~/.gpt-traffic-light/codex-hook` 的 8 项 hooks，审核后逐项信任；如未显示，点击 `Reload hooks`。CLI 中也可执行 `/hooks` 审核。只需信任本状态灯的命令。新版 Codex 要求信任新的或发生变化的 hook 定义，未信任的 hooks 不会执行。
2. 重新打开或新建一个**本地会话**，发送消息后观察状态灯。已经执行中的旧任务不会自动补发此前的事件。
3. 菜单分别显示 Codex 和浏览器状态；“打开 Codex”可以回到桌面应用。

“打开 Codex”只唤起应用，不会自动信任 hooks。程序会优先查找已运行或已注册的 Codex，也兼容 `/Applications/Codex.app`、`/Applications/ChatGPT.app` 和 `~/Applications` 下具有 Codex Bundle ID 的应用；启动失败会显示错误。Codex 设置深链只打开设置首页，需自行进入 Hooks。

事件映射：

| Codex 事件 | 状态 |
| --- | --- |
| `SessionStart` | 会话连接；保留已有执行状态 |
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | 🟡 执行中 |
| `PermissionRequest` | 🔴 等待授权 / 对应工具返回 |
| `Stop` / `Interrupt` | 🟢 本轮结束 / 已中断 |
| `SessionEnd` / Codex 进程退出 | 移除会话；没有其他来源时 ⚪ |

多个会话汇总优先级：🔴 > 🟡 > 🟢 > ⚪。一个会话结束不会掩盖另一个仍在执行的会话。没有收到任何 Codex hook 时显示离线，不把“未接入”当作空闲。

状态记录位于 `~/.gpt-traffic-light/codex-sessions`，仅包含进程标识、状态、轮次标识和授权请求摘要哈希，不保存提示词、命令、工具输出或回答。记录按会话隔离，并检查进程启动时间，避免崩溃或 PID 复用造成残留状态。

### Codex 剩余额度

用量通过[官方 app-server 配额接口](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)读取，需要本机 Codex CLI 支持 `account/rateLimits/read`，并已使用 ChatGPT 账号登录。API Key / Bedrock 登录不提供该套餐配额。

- 启动时查询，此后每 60 秒后台刷新；菜单内可点击“立即刷新用量”。查询不创建会话、不发送模型请求，单次最多等待约 15 秒。
- 菜单栏优先显示 `codex` 配额的主、次窗口，其他类别放在下拉详情中。如果只有其他类别，菜单栏会带上类别标识，避免混淆。
- 下拉详情显示剩余百分比、剩余进度条、重置时间及最近成功更新时间。时间使用本机时区。
- 剩余不超过 10% 时加 `!`；查询失败、有超过 90 秒未更新的缓存，或已到重置时间时，用 `≈` 标记旧百分比。不会自动推算恢复为 100%。
- 没有数据时显示 `--`，不会将查询失败当作 0%。网络失败时保留内存中的旧数据并标记；检测到未登录或不支持的登录方式时清除旧数据。
- 额度独立于红黄绿灯，灯色仍只表示执行状态。额度可在没有连接生命周期 hooks 时单独读取。
- 自动从运行中的 Codex 应用、标准应用目录和 PATH 查找 CLI。自定义安装可通过环境变量 `GPT_TRAFFIC_LIGHT_CODEX_BIN` 指定 CLI 的绝对路径；Finder 启动的应用不一定继承终端环境变量。

本应用只在内存中保存配额摘要，不直接读取或保存登录令牌，也不记录账号信息或原始接口响应。登录凭据由 Codex CLI 自身管理。

### ChatGPT 网页版（可选）

进入 Chrome `chrome://extensions`，启用开发者模式，选择“加载已解压的扩展程序”，加载：

`~/.gpt-traffic-light/extension`

在 Chrome 文件选择器中可使用 `Command + Shift + G` 粘贴路径。打开或刷新 `https://chatgpt.com`。

- 🟡 页面检测到停止生成按钮。
- 🔴 页面检测到可见授权 / 确认对话框（启发式）。
- 🟢 扩展连接正常，没有检测到生成或确认请求。
- ⚪ 12 秒未收到扩展心跳。

网页选择器可能随 ChatGPT 更新失效，必要时更新 `extension/content.js` 并重新加载扩展及网页。网页状态通过 `127.0.0.1:18765` 和安装时生成的随机令牌传输，不传输会话正文或 Cookie。

## 登录时启动

在 macOS“系统设置 → 通用 → 登录项”中添加 `~/Applications/GPTTrafficLight.app`。

## 卸载

退出状态灯后执行 `bash uninstall.sh`。脚本仅从 Codex 配置中移除本应用添加的 hooks，保留其他 hooks；然后删除应用和本应用数据。Chrome 扩展和登录项需自行移除。

## 验证

```bash
xcrun swiftc -O -parse-as-library mac/TrafficLight.swift mac/CodexMonitor.swift mac/CodexUsage.swift -framework AppKit -o /tmp/GPTTrafficLight
xcrun swiftc -O -parse-as-library mac/CodexMonitor.swift tests/CodexMonitorTests.swift -o /tmp/CodexMonitorTests
/tmp/CodexMonitorTests
xcrun swiftc -O -parse-as-library mac/CodexUsage.swift tests/CodexUsageTests.swift -o /tmp/CodexUsageTests
/tmp/CodexUsageTests
# 可选：真实只读查询，仅输出配额类别、剩余百分比和重置时间
/tmp/CodexUsageTests --live
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
bash -n install.sh uninstall.sh
```

自动化验证覆盖生命周期、并行会话、多个授权、旧轮次回调、中断、失效进程及配置合并；用量测试覆盖剩余比例、空值、多个配额类别、旧数据与重置标记、协议握手、超时及子进程清理。实际 Codex 回调和菜单栏显示仍需安装、信任 hooks 后验证；额度的真实读取可通过上述 `--live` 单独验证。

## 限制

- Codex 接入依据[官方生命周期 hooks](https://learn.chatgpt.com/docs/hooks)，不读取桌面窗口，也不依赖网页按钮；无需辅助功能或屏幕录制权限。
- 监测的是本机执行的 Codex 会话。使用相同用户 hooks 的 CLI / IDE 本地会话也会计入；远程主机或云端运行的任务不在本机覆盖范围内。
- `Stop` 表示本轮停止，不保证任务成功。其他 hook 让 Codex 继续执行时，后续事件会再次更新状态。
- 授权被允许或拒绝后，没有独立的“授权弹窗已关闭”事件。红灯在对应工具的 `PostToolUse` 或本轮结束 / 中断时清除；因此批准长时间命令后，红灯可能持续到命令返回。其他 hooks 自动批准的请求也可能短暂触发红灯。
- 普通提问、所有等待用户输入的控件、远程审批等不保证触发 `PermissionRequest`；红灯不覆盖全部等待场景。
- 只支持带有上述 hooks 的 Codex 版本；如果 hooks 被禁用、未信任或被组织策略限制，菜单会保持未连接。
