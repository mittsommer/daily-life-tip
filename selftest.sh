#!/bin/bash
# 用 appex 自己的源文件编译一份自检程序，验证小组件那一侧能跑。
#
# 跟 build.sh 的区别：这里把 LifeWidget.swift 换成 tools/widget-selftest.swift，
# 后者有 main，能直接跑；其余（Shared.swift + BookData.swift）完全一致。
# 所以它验的是 appex 真正会看到的那份数据和那套模型。
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
OUT="build/widget-selftest"

echo "==> 编译自检程序"
mkdir -p build
# -D SELFTEST 让 LifeWidget.swift 里的 @main WidgetBundle 让开，
# 否则跟测试文件的 @main 撞车（一个模块只能有一个入口点）。
swiftc -O -target "${TARGET}" \
  -D SELFTEST \
  -framework SwiftUI -framework WidgetKit -framework AppIntents \
  Sources/Shared.swift Widget/BookData.swift Widget/LifeWidget.swift tools/widget-selftest.swift \
  -o "${OUT}"

echo
echo "==> 运行"
# 状态全部写到临时目录，绝不碰 ~/Library/Application Support/LifeWidget ——
# 自检会切模式、写覆盖，写到真实位置会抹掉用户当天换过的那条。
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
LIFEWIDGET_STATE_DIR="$STATE" "${OUT}"
