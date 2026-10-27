#!/bin/bash
# Optional local developer installation; end users only need the built .app.
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) printf '不支持的处理器：%s\n' "$ARCH" >&2; exit 1 ;; esac
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-traffic-light-install.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
bash "$BASE/build.sh" "$ARCH" "$BUILD_DIR"
mkdir -p "$HOME/Applications"
# Remove the retired resource before copying the newly sealed app bundle.
rm -f "$HOME/Applications/GPTTrafficLight.app/Contents/Resources/codex_desktop_status.py"
/usr/bin/ditto "$BUILD_DIR/$ARCH/GPTTrafficLight.app" "$HOME/Applications/GPTTrafficLight.app"
printf '\n应用已安装：%s/Applications/GPTTrafficLight.app\n' "$HOME"
printf '启动后从菜单选择“配置 / 更新 Codex hooks…”，再到 Codex 审核信任。\n'
