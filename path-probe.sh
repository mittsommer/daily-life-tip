#!/bin/bash
# 实测沙盒进程能写哪些路径 —— 决定「换一条」的覆盖该往哪写。
#
# 背景：ad-hoc 签名（无 Team ID）下，appex 用 App Group 容器读写会被 TCC 拒：
#   kTCCServiceSystemPolicyAppData denied by TCC for LifeWidgetExtension
# 路径能解析出来（containermanagerd 返回 success），但读写被拒。
# 所以得换一个 appex 能写、宿主 app 也能读到的地方。
#
# 这个脚本把同一份探针按几种 entitlements 各签一次，跑同一个目标路径，
# 然后**从沙盒外**核对文件是否真的落在那个绝对路径上 ——
# 上一版探针就是栽在没做这步，把自己容器里的成功当成了 App Group 的成功。
set -uo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"
SUPPORT="$HOME/Library/Application Support/LifeWidget"
GROUP="$HOME/Library/Group Containers/group.com.local.lifewidget"
BUILD=build/probe

rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> 编译探针（用真实的 Shared.swift，路径解析逻辑完全一致）"
swiftc -O -target "${TARGET}" \
  Sources/Shared.swift Widget/BookData.swift tools/path-probe.swift \
  -o "${BUILD}/path-probe" || exit 1

# 造一个最小的 .app —— 裸二进制带 app-sandbox 会因为拿不到 bundle identifier
# 在启动时 SIGTRAP（libsystem_secinit）。真实 appex 永远在 bundle 里。
make_bundle() {
  local name="$1" ents="$2"
  local b="${BUILD}/${name}.app"
  mkdir -p "${b}/Contents/MacOS"
  cat > "${b}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.lifewidget.${name}</string>
  <key>CFBundleExecutable</key><string>path-probe</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
  cp "${BUILD}/path-probe" "${b}/Contents/MacOS/path-probe"
  codesign --force --sign - --timestamp=none --entitlements "$ents" "$b" 2>/dev/null
  echo "$b/Contents/MacOS/path-probe"
}

write_ents() {
  local out="$1"; shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '  <key>com.apple.security.app-sandbox</key><true/>'
    while [ $# -gt 0 ]; do
      local key="$1"; shift
      echo "  <key>${key}</key>"
      echo '  <array><string>group.com.local.lifewidget</string></array>'
    done
    echo '</dict></plist>'
  } > "$out"
}

# 外部核对：沙盒里那个 pid 写的文件，在目标绝对路径上到底有没有
verify_external() {
  local label="$1" dir="$2" pid="$3"
  local f="${dir}/probe-${pid}.json"
  if [ -f "$f" ]; then
    echo "   ✅ 外面看得见：$f"
    echo "      $(cat "$f")"
    rm -f "$f"
    return 0
  fi
  echo "   ❌ 外面看不到 $f —— 沙盒内那次「成功」不算数"
  return 1
}

run_case() {
  local label="$1" name="$2" ents="$3"; shift 3
  echo
  echo "=================================================================="
  echo "  $label"
  echo "=================================================================="
  local bin; bin="$(make_bundle "$name" "$ents")"
  echo "--- entitlements ---"
  codesign -d --entitlements - "${BUILD}/${name}.app" 2>/dev/null | grep -o 'com\.apple\.security\.[a-z.-]*' | sort -u | sed 's/^/   /'
  echo "--- 跑 ---"
  local out; out="$("$bin" "$@" 2>&1)"; local rc=$?
  echo "$out" | sed 's/^/   /'
  local pid; pid="$(echo "$out" | sed -n 's/^PROBE_PID=//p')"
  echo "--- 外部核对 ---"
  for d in "$@"; do verify_external "$label" "$d" "$pid" || true; done
}

# 1. 现状：app-sandbox + application-groups，写 App Group 容器
#    预期 ❌ —— TCC 会拒，这正是当前「换一条」失效的原因
write_ents "${BUILD}/ents-groups.plist" com.apple.security.application-groups
run_case "现状：App Group 容器（app-sandbox + application-groups）" \
  groups "${BUILD}/ents-groups.plist" "$GROUP" "$SUPPORT"

# 2. 候选 A：temporary-exception 读**写** Application Support
#    appex 写这里，宿主 app（非沙盒）读这里
cat > "${BUILD}/ents-rw.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.local.lifewidget</string></array>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
  <array><string>/Library/Application Support/LifeWidget/</string></array>
</dict></plist>
PLIST
run_case "候选 A：temporary-exception read-write 到 Application Support" \
  rw "${BUILD}/ents-rw.plist" "$SUPPORT"

# 3. 候选 B：appex 写自己的容器
#    宿主 app 非沙盒，理论上能读 ~/Library/Containers/<widget-id>/Data/...
run_case "候选 B：appex 自己的容器（任何沙盒进程天然可写）" \
  own "${BUILD}/ents-groups.plist" "$HOME/Library/Containers/com.local.lifewidget.widget/Data/Library/Application Support"

echo
echo "=================================================================="
echo "结论怎么读："
echo "  现状那组如果外部核对是 ❌，就证实了 App Group 走不通；"
echo "  哪一组外部核对是 ✅，那组就是这个构建下的可行路径。"
