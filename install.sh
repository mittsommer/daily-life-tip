#!/bin/bash
# 构建 → 装到 /Applications → 注册小组件。
# 小组件注册对安装位置敏感，/Applications 最稳，别装到别处。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="LifeWidget"
APP="/Applications/${APP_NAME}.app"
BUNDLE_ID="com.local.lifewidget"
WIDGET_ID="${BUNDLE_ID}.widget"
APPEX_NAME="LifeWidgetExtension"

./build.sh

echo
echo "==> 退出正在运行的旧版本"
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5

echo "==> 安装到 /Applications"
# 用 .pkg 装过一次之后，/Applications 里那份归 root（安装器以 root 写文件），
# 普通用户删不掉。以前这里会刷一屏 Permission denied 然后退出，旧版本原封不动 ——
# 看起来像「改了代码没生效」。
if [ -e "${APP}" ] && [ "$(stat -f %Su "${APP}")" != "$(id -un)" ]; then
  echo "❌ ${APP} 归 $(stat -f %Su "${APP}") 所有（之前用安装包装过），这里换不掉。二选一："
  echo "     ./package.sh 然后双击 dist/ 里的 .pkg 覆盖安装"
  echo "     sudo rm -rf \"${APP}\" 之后再跑 ./install.sh"
  exit 1
fi
rm -rf "${APP}"
cp -R "build/${APP_NAME}.app" "${APP}"

# 这里**不要**再 codesign 一次。签名在 build.sh 里已经做好，cp -R 原样搬运即可。
# 补签的时候如果漏了 --entitlements，会把 appex 的 app-sandbox 洗掉，
# pkd 就以 "plug-ins must be sandboxed" 静默拒收 —— 小组件在系统里根本搜不到。
# 校验一下搬运没坏：
if ! codesign -d --entitlements - "${APP}/Contents/PlugIns/${APPEX_NAME}.appex" 2>/dev/null | grep -q app-sandbox; then
  echo "⚠️  appex 的沙盒 entitlement 丢了，重新签一次"
  codesign --force --sign - --timestamp=none \
    --entitlements Widget/widget.entitlements "${APP}/Contents/PlugIns/${APPEX_NAME}.appex"
  codesign --force --sign - --timestamp=none "${APP}"
fi

echo "==> 注册小组件"
# 先让系统重新扫一遍所有插件，再单独注册这个
/usr/bin/pluginkit -a "${APP}/Contents/PlugIns/${APPEX_NAME}.appex" 2>/dev/null || true
/usr/bin/pluginkit -e use -i "${WIDGET_ID}" 2>/dev/null || true

echo "==> 启动宿主 app"
open "${APP}"

sleep 1.5
echo
if /usr/bin/pluginkit -m -i "${WIDGET_ID}" 2>/dev/null | grep -q .; then
  echo "✅ 小组件已注册"
else
  echo "⚠️  小组件没注册上。排查："
  echo "     pluginkit -m | grep lifewidget"
  echo "     log stream --predicate 'process == \"pkd\" or process == \"chronod\"'"
fi

cat <<'TIP'

在桌面上放上去：
  右键桌面 → 编辑小组件 → 搜「高性价比人生指南」→ 选尺寸拖出来

小尺寸只放标题，中尺寸放标题+说人话（主力），大尺寸铺开成本/收益/来源。
每天午夜自动换一条，同时放好几块也是同一条。
今天那条右上角有个小圆圈刷新标记，点一下就顺移到下一条（只影响今天，午夜自动失效）。
TIP
