#!/bin/bash
# Build distributable app bundles. Hook configuration happens inside the app menu.
set -euo pipefail
BASE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-all}"
OUTPUT="${2:-$BASE/dist}"
case "$MODE" in
  all) ARCHITECTURES=(arm64 x86_64) ;;
  arm64|x86_64) ARCHITECTURES=("$MODE") ;;
  *) printf '用法：bash build.sh [all|arm64|x86_64] [输出目录]\n' >&2; exit 1 ;;
esac
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gpt-traffic-light-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUTPUT"
for ARCH in "${ARCHITECTURES[@]}"; do
  APP="$BUILD_DIR/$ARCH/GPTTrafficLight.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  printf '正在编译 %s...\n' "$ARCH"
  xcrun swiftc -O -parse-as-library -target "$ARCH-apple-macosx12.0" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$BASE"/mac/*.swift -framework AppKit -o "$APP/Contents/MacOS/GPTTrafficLight"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.gpt.trafficlight</string>
<key>CFBundleExecutable</key><string>GPTTrafficLight</string>
<key>CFBundleName</key><string>GPTTrafficLight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  # Local ad-hoc signing only; release Developer ID signing/notarization is separate.
  /usr/bin/codesign --force --sign - "$APP"
  mkdir -p "$OUTPUT/$ARCH"
  /usr/bin/ditto "$APP" "$OUTPUT/$ARCH/GPTTrafficLight.app"
  if [ "$ARCH" = arm64 ]; then LABEL=AppleSilicon; else LABEL=Intel; fi
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/GPTTrafficLight-$LABEL.zip"
  printf '已生成：%s/%s/GPTTrafficLight.app\n安装归档：%s/GPTTrafficLight-%s.zip\n' "$OUTPUT" "$ARCH" "$OUTPUT" "$LABEL"
done
printf '\n将 App 拖入“应用程序”，启动后在菜单选择“配置 / 更新 Codex hooks…”，再到 Codex 审核信任。\n'
