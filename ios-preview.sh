#!/bin/bash
# 手机版（iPhone）界面预览。
#
#   ./ios-preview.sh            打开窗口，可以点、可以滚
#   ./ios-preview.sh --render   把四个页面各渲染成 PNG 到 build/phone/
#
# 关于「为什么是预览不是真的 iOS app」：iOS 的 SDK、模拟器、真机安装都只随 Xcode 提供，
# 这台机器只有 Command Line Tools。所以这里用 macOS 编译一个窗口大小等于 iPhone 屏幕的
# app，界面和逻辑与将来的 iOS 版共用同一份代码（Sources/Shared.swift、Widget/WidgetViews.swift、
# Sources/ShareCard.swift）。补 Xcode 工程时这部分不用重写。
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build
swiftc -O -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework SwiftUI -framework WidgetKit -framework AppIntents \
  Sources/Shared.swift Widget/BookData.swift Widget/WidgetViews.swift Sources/ShareCard.swift \
  ios/PhoneViews.swift ios/PhoneApp.swift \
  -o build/phone-preview

# 状态指到临时目录：预览里切模式、点换一条都不该动 Mac 版那份（见 selftest.sh）
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
export LIFEWIDGET_STATE_DIR="$STATE"

if [ "${1:-}" = "--render" ]; then
  build/phone-preview --render "${2:-build/phone}"
else
  build/phone-preview
fi
