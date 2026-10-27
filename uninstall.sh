#!/bin/bash
set -euo pipefail
# Unregister before deleting the application; preserve all foreign hook handlers.
APP="$HOME/Applications/GPTTrafficLight.app"
if [ ! -x "$APP/Contents/MacOS/GPTTrafficLight" ]; then APP="/Applications/GPTTrafficLight.app"; fi
if [ ! -x "$APP/Contents/MacOS/GPTTrafficLight" ]; then
  printf '请先在状态灯菜单选择“移除本应用 hooks…”，然后将 App 移到废纸篓。\n' >&2
  exit 1
fi
"$APP/Contents/MacOS/GPTTrafficLight" --remove-codex-hooks
osascript -e 'tell application "GPTTrafficLight" to quit' 2>/dev/null || true
rm -rf "$APP" "$HOME/.gpt-traffic-light"
printf '本应用 hooks 和本地文件已删除；其他 hooks 已保留，登录项需自行移除。\n'
