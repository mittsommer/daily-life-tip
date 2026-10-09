#!/bin/bash
# 构建 LifeWidget.app —— 不需要 Xcode，只用 Command Line Tools 里的 swiftc。
# 结构和 sc-usage-widget 一样：主 app + 嵌在 Contents/PlugIns/ 里的 WidgetKit appex。
#
# 唯一的实质区别：书的 672 条数据编译进 appex（Widget/BookData.swift），
# 所以小组件不依赖任何共享文件也能出内容。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LifeWidget"
APP="build/${APP_NAME}.app"
BUNDLE_ID="com.local.lifewidget"
WIDGET_NAME="LifeWidgetExtension"
WIDGET_ID="${BUNDLE_ID}.widget"
APPEX="${APP}/Contents/PlugIns/${WIDGET_NAME}.appex"
VERSION="${VERSION:-1.0.0}"
# app 自身更新去哪个 GitHub 仓库的 Releases 查新版本（用户名/仓库名）。
# 空着也能构建，菜单里的「检查新版本」会置灰。
UPDATE_REPO="${UPDATE_REPO:-}"
MIN_MACOS="14.0"        # WidgetKit 桌面小组件需要 Sonoma
# 默认只编本机架构（开发时快）。打安装包用 ARCHS="arm64 x86_64" 出通用二进制，
# 否则 Apple 芯片上编的包在 Intel Mac 上直接打不开。
ARCHS="${ARCHS:-$(uname -m)}"
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo 15.0)"

# 书的快照不在这个仓库里，用 ./book 或环境变量指定
BOOK_DIR="${BOOK_DIR:-}"

echo "==> 生成数据"
# 书稿不放进这个仓库（它有自己的仓库和协议）。第一次构建时浅克隆一份到 book/。
if [ -z "${BOOK_DIR}" ] && [ ! -d book ]; then
  echo "   本地没有书稿，从 eternity4719/HowToLiveBetter 拉取"
  rm -rf build/book-src
  git clone --depth 1 --quiet https://github.com/eternity4719/HowToLiveBetter.git build/book-src
  mv build/book-src/book book
  rm -rf build/book-src
fi
if [ -n "${BOOK_DIR}" ]; then
  node tools/embed.mjs "${BOOK_DIR}"
else
  node tools/embed.mjs
fi

APP_SOURCES=(
  Sources/Shared.swift
  Widget/BookData.swift
  Widget/WidgetViews.swift
  Sources/ShareCard.swift
  Sources/RemoteBook.swift
  Sources/AppUpdater.swift
  Sources/main.swift
)

# appex 需要 Shared.swift（条目模型 + 选条逻辑）和生成出来的 BookData.swift。
# 注意不含 RemoteBook.swift —— 联网在宿主 app 做，小组件保持离线可出图。
WIDGET_SOURCES=(
  Sources/Shared.swift
  Widget/BookData.swift
  Widget/WidgetViews.swift
  Widget/LifeWidget.swift
)

# 每个架构单独编一遍，再用 lipo 合成一个文件。swiftc 一次只认一个 -target。
#   compile <输出> <swiftc 参数…>
compile() {
  local out="$1"; shift
  local parts=()
  for arch in ${ARCHS}; do
    swiftc -O -target "${arch}-apple-macosx${MIN_MACOS}" "$@" -o "${out}.${arch}"
    parts+=("${out}.${arch}")
  done
  lipo -create "${parts[@]}" -output "${out}"
  rm -f "${parts[@]}"
}

echo "==> 清理"
rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "==> 编译主程序 (${ARCHS}, macOS ${MIN_MACOS}+)"
compile "${APP}/Contents/MacOS/${APP_NAME}" \
  -framework AppKit -framework SwiftUI -framework WidgetKit -framework AppIntents \
  "${APP_SOURCES[@]}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LifeWidget</string>
  <key>CFBundleDisplayName</key><string>今日一条</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTSDKName</key><string>macosx${SDK_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHumanReadableCopyright</key><string>正文 CC BY 4.0 · eternity4719/HowToLiveBetter</string>
  <!-- 菜单栏常驻：不进 Dock、不占 App 切换器 -->
  <key>LSUIElement</key><true/>
  <!-- lifewidget://share：小组件上的分享按钮靠它把宿主 app 叫起来 -->
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
    <key>CFBundleURLSchemes</key><array><string>lifewidget</string></array>
  </dict></array>
  <!-- app 自身更新：去这个仓库的 GitHub Releases 查新版本 -->
  <key>LWUpdateRepo</key><string>${UPDATE_REPO}</string>
</dict>
</plist>
PLIST

echo "==> 编译桌面小组件 (appex)"
mkdir -p "${APPEX}/Contents/MacOS"
# 入口点必须是 _NSExtensionMain（Xcode 构建的小组件也是这样，可用 nm -u 对比）。
# @main WidgetBundle 只负责生成类型元数据，真正的 XPC 握手由 NSExtensionMain 做。
compile "${APPEX}/Contents/MacOS/${WIDGET_NAME}" \
  -application-extension \
  -framework SwiftUI -framework WidgetKit -framework AppIntents \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "${WIDGET_SOURCES[@]}"

cat > "${APPEX}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleName</key><string>${WIDGET_NAME}</string>
  <key>CFBundleDisplayName</key><string>高性价比人生指南</string>
  <key>CFBundleExecutable</key><string>${WIDGET_NAME}</string>
  <key>CFBundleIdentifier</key><string>${WIDGET_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTSDKName</key><string>macosx${SDK_VERSION}</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

echo "==> 生成 AppIntents 元数据（「换一条」按钮的派发靠它）"
# 这段是这套无 Xcode 构建里最不直观的一步。交互式小组件按钮点击后不是就地跑
# perform() —— chronod 把点击交给 linkd，linkd 按 intent 的类型名查一份元数据，
# 查到才去调。这份元数据正常由 Xcode 的 appintentsmetadataprocessor 生成，
# 而它只在 Xcode 里（Command Line Tools 没有 AppIntentsMetadataExtractor.framework），
# 所以手工生成等价物。
#
# 少了它的表现是「按钮点得动、小组件永远不变」，chronod 日志里则是：
#   "There is no metadata for ShuffleIntent in com.local.lifewidget"
# 位置必须在编译之后（要核对二进制符号）、签名之前（签名把 Resources 封住）。
node tools/embed-appintents.mjs "${APPEX}/Contents/Resources"

echo "==> ad-hoc 签名（先 appex 再外层 app）"
# appex 必须带 app-sandbox entitlement，否则 pkd 以
# "plug-ins must be sandboxed" 拒绝注册。
codesign --force --sign - --timestamp=none \
  --entitlements Widget/widget.entitlements "${APPEX}"
codesign --force --sign - --timestamp=none "${APP}"

echo "==> 完成：${PWD}/${APP}"
echo
echo "安装并启用："
echo "  ./install.sh"
echo "看今天的条目（不起界面）："
echo "  \"${PWD}/${APP}/Contents/MacOS/${APP_NAME}\" --dump"
