#!/bin/bash
# 沙盒探针的驱动：同一份源码编两遍，一份不签（对照），一份签上小组件的 entitlements（沙盒）。
#
# 为什么要这么绕：小组件跑在沙盒里，而宿主 app 不在（它的 entitlements 是空的）。
# 所以「宿主 app 能写、命令行能读」证明不了沙盒那一侧也能读 ——
# 而读不到的表现是「按钮点得动、小组件永远不变」，光看界面看不出来。
#
# 实验组必须是**一个 bundle**，不能是光秃秃的可执行文件：
# 裸二进制带 app-sandbox 的话，libsystem_secinit 拿不到 bundle identifier
# 建不起容器身份，直接在启动时 SIGTRAP（exit 133）—— 会看起来像沙盒有问题，
# 其实是探针没搭对。真实 appex 永远在 bundle 里，所以这里也照做。
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
PLAIN="build/probe-plain"
BUNDLE="build/SandboxProbe.app"
SANDBOXED="${BUNDLE}/Contents/MacOS/SandboxProbe"

mkdir -p build

echo "==> 编译探针（跟 appex 同一份 Shared.swift + BookData.swift）"
# BookData.swift 必须带上：Shared.swift 里的兜底数据引用了它，
# 而且这样探针读的就是 appex 真正会读的那份。
swiftc -O -target "${TARGET}" \
  Sources/Shared.swift Widget/BookData.swift tools/sandbox-probe.swift \
  -o "${PLAIN}"

echo "==> 搭最小 bundle（secinit 要求有 bundle identifier）"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
cat > "${BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.local.lifewidget.sandboxprobe</string>
  <key>CFBundleExecutable</key><string>SandboxProbe</string>
  <key>CFBundleName</key><string>SandboxProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
cp "${PLAIN}" "${SANDBOXED}"
codesign --force --sign - --timestamp=none \
  --entitlements Widget/widget.entitlements "${BUNDLE}"

echo
echo "==> 签上的 entitlements（确认没写丢）"
codesign -d --entitlements - "${BUNDLE}" 2>/dev/null | grep -o 'com\.apple\.security\.[a-z.-]*' | sort -u

echo
echo "================ 对照组：不签（等同宿主 app 的环境） ================"
"${PLAIN}" || true

echo
echo "================ 实验组：签了 app-sandbox（等同 appex 的环境） ================"
"${SANDBOXED}" || true

echo
echo "说明：两组唯一差别就是沙盒。实验组里读不到共享文件 = 小组件的「换一条」不会生效。"
