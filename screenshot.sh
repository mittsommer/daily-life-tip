#!/bin/bash
# 重新生成 README 里的截图（docs/screenshot-{light,dark}.png）。
# 用的是小组件同一份视图代码，界面改了跑一遍就行。
set -euo pipefail

cd "$(dirname "$0")"

# 跟 selftest.sh 一样：-D SELFTEST 让 LifeWidget.swift 的 @main 让开
mkdir -p build
swiftc -O -target "$(uname -m)-apple-macosx14.0" \
  -D SELFTEST \
  -framework SwiftUI -framework WidgetKit -framework AppIntents \
  Sources/Shared.swift Widget/BookData.swift Widget/LifeWidget.swift tools/render-screenshot.swift \
  -o build/render-screenshot

# 状态指到临时目录：渲染不该碰用户的真实设置（见 selftest.sh）
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
LIFEWIDGET_STATE_DIR="$STATE" build/render-screenshot docs
