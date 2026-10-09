import SwiftUI
import WidgetKit
import AppIntents

// 《高性价比人生指南》桌面小组件
//
// 每天一条，午夜自动换。数据编译在二进制里（Sources/Shared.swift + Widget/BookData.swift），
// 宿主 app 联网拉到新版时会写一份缓存覆盖它。

// MARK: - 时间线

struct DailyProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyEntry {
        DailyEntry(date: Date(), item: DailyProvider.sample, isToday: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyEntry) -> Void) {
        // 小组件库里预览时给一条有代表性的，别让用户看到空白
        let item = context.isPreview ? DailyProvider.sample : Book.today()
        completion(DailyEntry(date: Date(), item: item, isToday: true))
    }

    /// 一次铺 8 天，而不是只给今天 + 「午夜后再来」。
    ///
    /// 原因是系统的刷新调度只把我们的建议当参考 —— 它可能延迟几小时才来取新时间线。
    /// 只给一天的话，用户第二天早上看到的还是昨天那条。铺 8 天 + .atEnd，
    /// 就算系统整天不来敲门，桌面上显示的也是当天该显示的那条。
    static let horizonDays = 8

    /// 真正算出要铺的条目。刻意不碰 `Context` ——
    /// `TimelineProviderContext` 用户构造不出来，逻辑埋在里面就没法离线自检
    /// （见 selftest.sh：只有能这样调，才能在拖到桌面之前发现数据是空的）。
    static func buildEntries(now: Date = Date(), days: Int = DailyProvider.horizonDays, calendar cal: Calendar = .current) -> [DailyEntry] {
        let startOfToday = cal.startOfDay(for: now)
        let payload = Book.load()

        var entries: [DailyEntry] = []
        for offset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            let item: Item? = payload.flatMap { p in
                guard !p.items.isEmpty else { return nil }
                // 走 TodayPick：今天那条会被用户的「换一条」覆盖，未来几天不受影响
                let idx = TodayPick.index(for: day, count: p.items.count, calendar: cal)
                return p.items[min(idx, p.items.count - 1)]
            }
            // 今天这条的 date 用真实的 now，不是零点 —— 免得系统认为它在过去
            entries.append(DailyEntry(date: offset == 0 ? now : day, item: item, isToday: offset == 0))
        }
        return entries
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyEntry>) -> Void) {
        // 条目用尽后请系统来取下一批
        completion(Timeline(entries: DailyProvider.buildEntries(), policy: .atEnd))
    }

    /// 小组件库预览用
    static let sample = Item(
        i: 0, c: 1, ct: "不要早死", n: 1,
        t: "系安全带，前排后排都系",
        k: "不花钱。每次上车多花 2 秒。",
        p: "坐前排系上安全带，出车祸时被撞死的概率大约降一半。坐轻型卡车前排的降六成。",
        g: "美国交通安全主管部门（NHTSA）估计，系安全带能让轿车前排乘员受致命伤的风险下降 45%。",
        e: "A", q: "",
        s: ["crashstats.nhtsa.dot.gov", "who.int"],
        m: "钱0 · 时少 · 收益大")
}

// MARK: - 注册

struct LifeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LifeWidget", provider: DailyProvider()) { entry in
            LifeWidgetView(entry: entry)
        }
        .configurationDisplayName("高性价比人生指南")
        .description("每天一条：花掉什么，换回什么，证据有多硬")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// selftest.sh 会定义 SELFTEST 并让测试文件提供 main ——
// 一个模块里只能有一个入口点，这样两边都能编译。
#if !SELFTEST
@main
struct LifeWidgetBundle: WidgetBundle {
    var body: some Widget {
        LifeWidget()
    }
}
#endif
