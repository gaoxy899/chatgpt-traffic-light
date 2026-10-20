#!/bin/bash
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
osascript -e 'tell application "GPTTrafficLight" to quit' 2>/dev/null || true
python3 "$BASE/scripts/configure_codex_hooks.py" --remove
rm -rf "$HOME/Applications/GPTTrafficLight.app" "$HOME/.gpt-traffic-light"
echo '本地文件已删除；请在 chrome://extensions 手动移除扩展，并在登录项设置中关闭自动启动（如已添加）。'
