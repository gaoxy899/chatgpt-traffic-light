#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/GPTTrafficLight.app"
EXT="$HOME/.gpt-traffic-light/extension"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-traffic-light-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT"
TOKEN_FILE="$HOME/.gpt-traffic-light/token"
if [ ! -f "$TOKEN_FILE" ]; then
  python3 -c 'import secrets; print(secrets.token_hex(24))' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"
python3 - "$BASE/mac/TrafficLight.swift" "$BUILD_DIR/TrafficLight.swift" "$BASE/extension/background.js" "$EXT/background.js" "$TOKEN" <<'PY'
from pathlib import Path
import sys
src, dst, js_src, js_dst, key = sys.argv[1:]
Path(dst).write_text(Path(src).read_text().replace('__TOKEN__', key))
Path(js_dst).write_text(Path(js_src).read_text().replace('__TOKEN__', key))
PY
cp "$BASE/extension/manifest.json" "$BASE/extension/content.js" "$EXT/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.gpt.trafficlight</string>
<key>CFBundleExecutable</key><string>GPTTrafficLight</string>
<key>CFBundleName</key><string>GPTTrafficLight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '正在编译 macOS 菜单栏程序...\n'
xcrun swiftc -O -parse-as-library "$BUILD_DIR/TrafficLight.swift" "$BASE/mac/CodexMonitor.swift" "$BASE/mac/CodexUsage.swift" "$BASE/mac/CodexDesktopStatus.swift" -framework AppKit -o "$BUILD_DIR/GPTTrafficLight"
# Monitoring is native Swift; remove the former runtime helper on upgrades.
rm -f "$APP/Contents/Resources/codex_desktop_status.py"
cp "$BUILD_DIR/GPTTrafficLight" "$APP/Contents/MacOS/GPTTrafficLight.new"
mv -f "$APP/Contents/MacOS/GPTTrafficLight.new" "$APP/Contents/MacOS/GPTTrafficLight"
cp "$BUILD_DIR/GPTTrafficLight" "$HOME/.gpt-traffic-light/codex-hook.new"
mv -f "$HOME/.gpt-traffic-light/codex-hook.new" "$HOME/.gpt-traffic-light/codex-hook"
chmod +x "$APP/Contents/MacOS/GPTTrafficLight"
python3 "$BASE/scripts/configure_codex_hooks.py" --binary "$HOME/.gpt-traffic-light/codex-hook"
printf '\n安装完成：\n  macOS App: %s\n  Chrome 扩展目录: %s\n\n' "$APP" "$EXT"
printf '执行 open "%s" 启动 App，然后到 chrome://extensions → 开发者模式 → 加载已解压的扩展程序，选择上述扩展目录。\n' "$APP"
printf '\nCodex 桌面版：已添加本地生命周期 hooks，原有 hooks 保留并备份。\n'
printf '请在 Codex 中审核并信任新增 hooks（CLI 可执行 /hooks），然后重新打开或新建本地会话。\n'
printf '只监测 Codex 时无需安装 Chrome 扩展。升级前请先退出旧的状态灯 App。\n'
