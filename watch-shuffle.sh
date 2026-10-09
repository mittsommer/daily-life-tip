#!/bin/bash
# 验证「换一条」按钮真的派发了。
#
# 为什么需要专门验：这个按钮失败时**没有任何界面反馈**。点下去不会报错、
# 不会动画、小组件也不变 —— 唯一的证据在 chronod 的日志和共享文件里。
# 所以这里一边盯日志，一边盯那个覆盖文件，让用户点一下就能看出成没成。
#
# 用法：./watch-shuffle.sh   然后去点小组件右上角那个小圆圈刷新标记
set -uo pipefail

cd "$(dirname "$0")"

GROUP="group.com.local.lifewidget"
# 「换一条」的覆盖可能落在两处，取决于谁写的：
#   小组件（沙盒）→ 自己的容器；宿主 app（非沙盒）→ Application Support
# 两边都要盯。以前只盯 App Group 那份 —— 那个位置永远不会有文件，
# 于是脚本一路报「没变化」，跟着把排查带偏了。
OVERRIDES=(
  "$HOME/Library/Group Containers/${GROUP}/pick-override.json"
  "$HOME/Library/Application Support/LifeWidget/pick-override.json"
  "$HOME/Library/Containers/com.local.lifewidget.widget/Data/Library/Application Support/LifeWidget/pick-override.json"
)

snapshot() {
  for f in "${OVERRIDES[@]}"; do
    if [ -f "$f" ]; then echo "$f: $(cat "$f")"; fi
  done
}

echo "盯着小组件的「换一条」。现在去点右上角那个小圆圈刷新标记。"
echo "（Ctrl-C 退出）"
echo
echo "日志里只有两种可能："
echo "  ✅ Successfully ran action 或 finished successfully  → 派发成功"
echo "  ❌ There is no metadata for ShuffleIntent            → 元数据没被认，按钮是死的"
echo

LOG=/tmp/lifewidget-shuffle.log
: > "$LOG"

# /usr/bin/log 写全路径：log 是 zsh 内置命令，会吃掉 --predicate 的参数，
# 用裸 `log` 会得到「什么都没发生」的假象（这个坑踩过一次）。
/usr/bin/log stream --style compact --level debug \
  --predicate 'process == "chronod" AND (eventMessage CONTAINS "interaction" OR eventMessage CONTAINS "Shuffle" OR eventMessage CONTAINS "metadata")' \
  > "$LOG" 2>&1 &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT

BEFORE=$(snapshot)
echo "点击前的覆盖文件："
if [ -z "$BEFORE" ]; then echo "  （一个都没有）"; else echo "$BEFORE" | sed 's/^/  /'; fi
echo

# 一边刷日志一边看那些文件
while true; do
  if [ -s "$LOG" ]; then
    while IFS= read -r line; do
      case "$line" in
        *"There is no metadata"*) echo "❌ $line" ;;
        *"Successfully ran action"*|*"finished successfully"*) echo "✅ $line" ;;
        *"Handle interaction"*|*"Received action"*) echo "👆 $line" ;;
        *error*|*Error*|*error=*) echo "⚠️  $line" ;;
        *) echo "   $line" ;;
      esac
    done < "$LOG"
    : > "$LOG"
  fi

  NOW=$(snapshot)
  if [ "$NOW" != "$BEFORE" ]; then
    echo
    echo "✅ 覆盖文件变了："
    echo "$NOW" | sed 's/^/   /'
    echo
    echo "覆盖已写入 = perform() 跑到了。小组件会在几秒内重画成下一条。"
    echo "（文件变了但小组件没变的话，看时间线重载那一步。）"
    BEFORE="$NOW"
  fi
  sleep 0.4
done
