#!/bin/bash
# 打包并发布到 GitHub Releases。已装的 app 会在菜单里看到「更新到 x.y.z」。
#
# 用法：VERSION=1.1.0 ./release.sh
#       VERSION=1.1.0 NOTES="这次改了什么" ./release.sh
#
# 需要先登录 gh（gh auth login）。版本号必须比上一次发布的大，
# 否则已装的 app 不会认为它是新版本。
set -euo pipefail

cd "$(dirname "$0")"

export UPDATE_REPO="${UPDATE_REPO:-mittsommer/daily-life-tip}"
: "${VERSION:?用法：VERSION=1.1.0 ./release.sh}"
export VERSION
NOTES="${NOTES:-}"
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"
TAG="v${VERSION}"

[ -x "${GH}" ] || { echo "❌ 找不到 gh"; exit 1; }
"${GH}" auth status >/dev/null 2>&1 || { echo "❌ gh 没登录：gh auth login"; exit 1; }

if "${GH}" release view "${TAG}" -R "${UPDATE_REPO}" >/dev/null 2>&1; then
  echo "❌ ${TAG} 已经发布过了，换个版本号"
  exit 1
fi

# 代码没提交就发布，发出去的安装包和仓库里的代码对不上
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 有没提交的改动，先 git commit"
  git status --short
  exit 1
fi
git push --quiet origin HEAD

./selftest.sh >/dev/null || { echo "❌ 自检没过，不发布（./selftest.sh 看详情）"; exit 1; }
./package.sh

DMG="dist/LifeWidget-${VERSION}.dmg"
echo
echo "==> 发布 ${TAG} 到 ${UPDATE_REPO}"
"${GH}" release create "${TAG}" "${DMG}" \
  -R "${UPDATE_REPO}" \
  --target "$(git rev-parse HEAD)" \
  --title "${VERSION}" \
  --notes "${NOTES:-版本 ${VERSION}}"

echo "✅ 已发布：https://github.com/${UPDATE_REPO}/releases/tag/${TAG}"
