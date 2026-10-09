// 沙盒探针：验证 appex 在**沙盒里**能不能读到宿主 app 写的共享文件。
//
// 存在的理由：宿主 app 不在沙盒里（它的 entitlements 是空的），所以
// `--shuffle` 验的是非沙盒那条路。而小组件跑在沙盒里 —— 如果沙盒读不到
// App Group，按钮会「看起来能点、小组件永远不变」，是个很难查的假象。
//
// 这个程序用同一份 Shared.swift，跑两种签名：
//   build/probe-plain      不签  → 对照组
//   build/probe-sandboxed  签上 Widget/widget.entitlements → 沙盒
// 驱动见 sandbox-probe.sh。
//
// 只验小组件真正会做的两件事：读书稿缓存、读写「换一条」的覆盖。

import Foundation

@main
struct SandboxProbe {
    static func main() {
        var fail = false
        let home = NSHomeDirectory()
        // 沙盒生效的可观测特征是家目录被搬到 Containers 下
        let sandboxed = home.contains("/Library/Containers/")
        print("沙盒生效：\(sandboxed ? "是" : "否")")
        print("  NSHomeDirectory → \(home)")
        print("  realHome        → \(SharedPaths.realHome)")

        // 1. 组容器能否解析
        let viaAPI = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedPaths.appGroup)?.path
        print("  containerURL    → \(viaAPI ?? "nil（沙盒外正常，代码里有 realHome 兜底）")")
        guard let groupDir = SharedPaths.groupDir else {
            print("❌ 组目录解析不出来 —— 小组件读不到任何共享文件")
            exit(1)
        }
        let exists = FileManager.default.fileExists(atPath: groupDir)
        print("\(exists ? "✅" : "❌") 组目录存在：\(groupDir)")
        if !exists { fail = true }

        // 2. 读缓存 —— 小组件联网更新后要做的就是这件事
        if let cache = ItemsCache.read() {
            print("✅ 读到书稿缓存：\(cache.payload.items.count) 条（\(cache.fetchedAt)）")
            if cache.payload.items.count != 672 {
                print("⚠️  条数是 \(cache.payload.items.count)，预期 672")
            }
        } else {
            print("⚠️  没读到缓存 —— 沙盒外可能确实没有；沙盒内读不到则是 bug")
            if sandboxed { fail = true }
        }

        // 3. 「换一条」的覆盖：写进去再读回来，正是按钮要做的事
        let today = Date()
        let marker = 42
        PickOverride.write(day: DailyPick.dayKey(for: today), index: marker)
        if let got = PickOverride.current(for: today), got == marker {
            print("✅ 覆盖写入后读回一致（\(marker)）")
        } else {
            let got = PickOverride.current(for: today).map(String.init) ?? "nil"
            print("❌ 覆盖读回不一致：写 \(marker)，读 \(got) —— 点「换一条」不会有反应")
            fail = true
        }

        // 4. 日期绑定：拿昨天去问必须当作没有
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: today),
           PickOverride.current(for: y) == nil {
            print("✅ 覆盖绑定了日期，跨天自动失效")
        } else {
            print("❌ 覆盖没绑日期")
            fail = true
        }

        PickOverride.clear()

        // 5. 兜底路径：家里那份（靠 temporary-exception 才能读）
        let fallback = SharedPaths.appSupportDir + "/" + SharedPaths.cacheName
        let fallbackReadable = FileManager.default.contents(atPath: fallback) != nil
        print("  \(fallbackReadable ? "ok" : "--") 兜底路径可读：\(fallback)")

        print(fail ? "\n❌ 有项目没过" : "\n✅ 全部通过")
        exit(fail ? 1 : 0)
    }
}
