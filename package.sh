#!/bin/bash
# 打安装盘：dist/LifeWidget-<版本>.dmg
#
# 打开后是「LifeWidget.app」和一个「应用程序」快捷方式，拖过去就装好了。
# 小组件的注册由 app 第一次启动时自己做（见 main.swift 的 SelfRegister），
# 所以不需要 .pkg 那种安装脚本。
#
# 用法：./package.sh            （版本号默认 1.0.0）
#       VERSION=1.1.0 ./package.sh
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LifeWidget"
APPEX_NAME="LifeWidgetExtension"
VOLUME_NAME="今日一条"
export VERSION="${VERSION:-1.0.0}"

# 通用二进制：Apple 芯片和 Intel 都能装
ARCHS="arm64 x86_64" ./build.sh

APP="build/${APP_NAME}.app"
STAGE="build/dmg"
OUT="dist/${APP_NAME}-${VERSION}.dmg"

echo
echo "==> 核对构建产物"
for bin in "${APP}/Contents/MacOS/${APP_NAME}" "${APP}/Contents/PlugIns/${APPEX_NAME}.appex/Contents/MacOS/${APPEX_NAME}"; do
  echo "   $(basename "$bin")：$(lipo -archs "$bin")"
done
# 沙盒 entitlement 丢了小组件会被 pkd 静默拒收，装完在系统里搜不到 —— 打包前必须确认
codesign -d --entitlements - "${APP}/Contents/PlugIns/${APPEX_NAME}.appex" 2>/dev/null | grep -q app-sandbox \
  || { echo "❌ appex 没有 app-sandbox entitlement"; exit 1; }
[ -f "${APP}/Contents/PlugIns/${APPEX_NAME}.appex/Contents/Resources/Metadata.appintents/extract.actionsdata" ] \
  || { echo "❌ 缺 AppIntents 元数据，「换一条」按钮会是死的"; exit 1; }
codesign --verify --deep --strict "${APP}" || { echo "❌ 签名校验失败"; exit 1; }
echo "   签名 / 沙盒 / AppIntents 元数据 都在"

rm -rf "${STAGE}"
mkdir -p "${STAGE}" dist
# ditto 而不是 cp：保留扩展属性和签名封口
ditto "${APP}" "${STAGE}/${APP_NAME}.app"
ln -s /Applications "${STAGE}/应用程序"

cat > "${STAGE}/安装说明.txt" <<'TXT'
安装
  把「LifeWidget」拖到旁边的「应用程序」文件夹，然后从「应用程序」里打开它。
  菜单栏会出现一本小书的图标「今日一条」。

把小组件放到桌面
  右键桌面 → 编辑小组件 → 搜「高性价比人生指南」→ 选尺寸拖出来。

如果提示「无法验证开发者」
  这个 app 没有 Apple 开发者签名，第一次打开会被系统拦下：
    1. 在提示框点「完成」
    2. 打开「系统设置 → 隐私与安全性」，往下找到 LifeWidget，点「仍要打开」
    3. 输入密码，之后就能正常打开了

升级
  菜单栏里点「检查新版本…」，有新版会自动下载替换。
  也可以手动把新版本拖进「应用程序」替换。选条方式和今天换过的那条都会保留。

卸载
  退出菜单栏里的 app，把「应用程序」里的 LifeWidget 拖进废纸篓。

书的正文：《高性价比人生指南》，CC BY 4.0，github.com/eternity4719/HowToLiveBetter
TXT

echo "==> 打包"
rm -f "${OUT}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE}" \
  -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 \
  -ov "${OUT}" >/dev/null

echo "==> 完成：${PWD}/${OUT}（$(du -h "${OUT}" | cut -f1)）"
if [ -z "${UPDATE_REPO:-}" ]; then
  echo "⚠️  没设 UPDATE_REPO，这个版本里「检查新版本」是灰的。发布用：UPDATE_REPO=用户名/仓库名 VERSION=${VERSION} ./package.sh"
fi
