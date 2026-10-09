// 只测小组件本体：用 appex 的同一套源文件，跑它的时间线构造和选条逻辑。
//
// 存在的理由：pluginkit 显示「已注册」只说明 Info.plist 和签名合格，
// 不代表 appex 跑得起来 —— BookData 的 JSON 解不开、条目模型对不上，
// 都要等用户拖到桌面上才看得出来是空白的小组件。
//
// 编译运行见 selftest.sh。用 @main 而不是顶层语句，因为要跟源文件一起
// 以 -parse-as-library 编译（见那边注释）。

import Foundation

@main
struct WidgetSelfTest {
    static func main() {
        // 自检会切模式、写覆盖。没指到临时目录就拒绝跑，免得抹掉用户的真实状态。
        guard let stateDir = ProcessInfo.processInfo.environment["LIFEWIDGET_STATE_DIR"], !stateDir.isEmpty else {
            print("❌ 要通过 selftest.sh 跑（它会把 LIFEWIDGET_STATE_DIR 指到临时目录）")
            exit(2)
        }
        print("   状态目录：\(stateDir)")
        let cal = Calendar.current
        var failed = false

        // 1. 内置数据在 appex 这一侧解得开吗
        guard let payload = Book.load(preferCache: false) else {
            print("❌ BookData.json 解不开 —— 小组件会是空白的")
            exit(1)
        }
        print("✅ 内置数据解开：\(payload.items.count) 条，\(payload.chapters.count) 节，书名「\(payload.title)」")
        // 不写死条数：书稿在持续更新（672 → 675…）。只拦「明显解析坏了」的情况，
        // 门槛跟 ItemsCache 拒收残缺缓存的一致。
        if payload.items.count <= 100 {
            print("❌ 只解出 \(payload.items.count) 条 —— 解析器跟书稿格式对不上了")
            failed = true
        }

        // 2. 小组件库里的预览条目
        print("✅ 预览条目：\(DailyProvider.sample.t.prefix(30))")

        // 3. 时间线铺开（跟小组件真正会渲染的是同一条路）
        let entries = DailyProvider.buildEntries()
        guard !entries.isEmpty else {
            print("❌ 时间线是空的")
            exit(1)
        }
        print("✅ 时间线铺了 \(entries.count) 天：")
        for e in entries {
            let day = DailyPick.dayKey(for: e.date)
            let mark = e.isToday ? "今天" : "    "
            guard let item = e.item else { print("   \(day) \(mark)  ❌ 没条目"); failed = true; continue }
            print("   \(day) \(mark)  第\(item.c)节第\(item.n)条  \(item.t.prefix(34))")
        }

        // 4/5. 两种选条方式各测一遍（状态都在临时目录里，随便切）。
        let today = Date()
        let n = payload.items.count
        let start = cal.startOfDay(for: today)
        let day: (Int) -> Date = { cal.date(byAdding: .day, value: $0, to: start) ?? start }

        for mode in PickMode.allCases {
            Settings.update { $0.mode = mode; $0.startDay = DailyPick.dayKey(for: today) }
            TodayPick.resetForModeChange()
            print("── \(mode.title) ──")

            // 同一天反复算必须是同一条：「同时放好几块小组件显示同一条」的前提
            let first = DailyPick.index(for: today, count: n)
            let stable = (0..<200).allSatisfy { _ in DailyPick.index(for: today, count: n) == first }
            print(stable ? "✅ 同一天 200 次结果一致" : "❌ 同一天结果不稳定 —— 小组件会自己乱跳")
            if !stable { failed = true }

            switch mode {
            case .sequential:
                // 必须真的是 +1，并且 n 天恰好走完整本书、不重不漏
                let idx = (0..<n).map { DailyPick.index(for: day($0), count: n) }
                let stepOK = zip(idx, idx.dropFirst()).allSatisfy { ($0 + 1) % n == $1 }
                let fromStart = idx.first == 0
                let full = Set(idx).count == n
                print(stepOK && fromStart && full
                      ? "✅ 从第 1 条起每天 +1，\(n) 天恰好走完整本书"
                      : "❌ 顺序不对：起点 \(idx.first ?? -1)，逐日 +1 \(stepOK)，覆盖 \(Set(idx).count)/\(n)")
                if !(stepOK && fromStart && full) { failed = true }

            case .random:
                // 抽 3n 天：随机模式每次抽签都要读写整张表，天数越多越慢（平方级），
                // 3n 天已够卡方检验用，覆盖期望 1-e⁻³ ≈ 95%。
                let days = n * 3
                var seen = Set<Int>()
                var histogram = [Int](repeating: 0, count: 32)
                var repeats = 0
                var seq: [Int] = []
                for d in 0..<days {
                    let i = DailyPick.index(for: day(d), count: n)
                    seen.insert(i)
                    histogram[i * histogram.count / n] += 1
                    // 前 7 天里出现过就算近处重复
                    if seq.suffix(7).contains(i) { repeats += 1 }
                    seq.append(i)
                }
                print("✅ \(days) 天覆盖 \(seen.count)/\(n) 条（期望约 95%）")
                if seen.count < n * 90 / 100 {
                    print("⚠️  覆盖偏低 —— 有区段抽不到"); failed = true
                }
                var chi2 = 0.0
                for b in 0..<histogram.count {
                    // 每个桶里的下标个数不完全相同，期望值按桶真实宽度算
                    let width = (b + 1) * n / histogram.count - b * n / histogram.count
                    let want = Double(days) * Double(width) / Double(n)
                    let diff = Double(histogram[b]) - want
                    chi2 += diff * diff / want
                }
                print("✅ 卡方 \(String(format: "%.1f", chi2))（32 桶，自由度 31，拒绝线约 53）")
                if chi2 > 53 { print("⚠️  分布不均"); failed = true }
                // 一周内同一条出现两次，用户就会觉得「这不是随机」。代码里专门防了，必须是 0
                print(repeats == 0 ? "✅ 任意 7 天内没有重复" : "❌ 7 天内重复出现 \(repeats) 次")
                if repeats != 0 { failed = true }
            }

            // 「换一条」：顺序模式必须 +1；随机模式必须**不是** +1（以前是，用户一眼看出不随机）
            PickOverride.clear()
            var prevIdx = TodayPick.index(for: today, count: n)
            var plusOne = 0, same = 0
            let clicks = 30
            for _ in 0..<clicks {
                guard let next = TodayPick.advance(today) else { break }
                if next == (prevIdx + 1) % n { plusOne += 1 }
                if next == prevIdx { same += 1 }
                prevIdx = next
            }
            PickOverride.clear()
            switch mode {
            case .sequential:
                let ok = plusOne == clicks
                print(ok ? "✅ 换一条：连点 \(clicks) 次每次 +1" : "❌ 换一条不是 +1：\(plusOne)/\(clicks)")
                if !ok { failed = true }
            case .random:
                // 随机下恰好落到下一条的概率 1/672，30 次里出现 2 次以上就不对
                let ok = plusOne <= 1 && same == 0
                print(ok ? "✅ 换一条：连点 \(clicks) 次是随机跳（顺移 \(plusOne) 次，原地 \(same) 次）"
                         : "❌ 换一条不随机：顺移 \(plusOne) 次、原地不动 \(same) 次")
                if !ok { failed = true }
            }
        }

        // 6. 空值和超长字段：小组件最怕的就是这两种
        let emptyCost = payload.items.filter { $0.k.isEmpty }.count
        let emptyPlain = payload.items.filter { $0.p.isEmpty }.count
        let longestTitle = payload.items.map { $0.t.count }.max() ?? 0
        print("✅ 空成本 \(emptyCost) 条，空说人话 \(emptyPlain) 条，最长标题 \(longestTitle) 字")
        if longestTitle > 60 {
            print("⚠️  最长标题 \(longestTitle) 字，小尺寸可能显示不全")
        }

        // 7. 「换一条」的覆盖：只认今天，昨天那份必须自动失效，清空后回到按模式算的那条
        let key = DailyPick.dayKey(for: today)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        PickOverride.clear()
        let base = TodayPick.index(for: today, count: n)
        PickOverride.write(day: key, index: (base + 1) % n)
        let after = TodayPick.index(for: today, count: n)
        if after == (base + 1) % n {
            print("✅ 覆盖生效：\(base) → \(after)")
        } else {
            print("❌ 覆盖没生效：写入了 \((base + 1) % n)，读回来是 \(after)")
            failed = true
        }
        if PickOverride.current(for: yesterday) == nil {
            print("✅ 跨天自动失效：昨天的覆盖对今天不生效")
        } else {
            print("❌ 覆盖没有跟日期绑定 —— 明天会继续显示今天手动换的那条")
            failed = true
        }
        PickOverride.clear()
        if TodayPick.index(for: today, count: n) == base {
            print("✅ 清空后回到按模式算的那一条")
        } else {
            print("❌ 清空后没回到原条")
            failed = true
        }

        print(failed ? "\n⚠️  有项目没过，见上" : "\n✅ 全部通过")
        exit(failed ? 1 : 0)
    }
}
