import Foundation
import os

// 宿主 app 和 WidgetKit 桌面小组件之间的共享层。
//
// 跟 sc-usage-widget 一样的分工，但这里有个关键区别：
// 书的 672 条数据**编译进二进制**（Widget/BookData.swift），小组件不读文件也能出内容。
// 共享层只承担一件事 —— 宿主 app 联网拉到的新版数据，覆盖内置的那份快照。
// 所以缓存缺失、App Group 建不出来、app 从没跑过，小组件都照样显示，只是数据停在
// 编译时的那个版本。这条是刻意的：宁可显示旧的一条，也不要开天窗。

enum SharedPaths {
    static let appGroup = "group.com.local.lifewidget"

    /// 沙盒里 NSHomeDirectory() 变成容器路径，这里要的是真实家目录。
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// 真实家目录下那份。宿主 app 写这里；小组件靠 temporary-exception（读写）也写这里，
    /// 两边共用一份，`--today` 看到的就是用户点按钮选的那条。
    static var appSupportDir: String {
        realHome + "/Library/Application Support/LifeWidget"
    }

    /// **本进程自己**的可写位置。
    ///
    /// 沙盒进程里 NSHomeDirectory() 是容器路径（…/Library/Containers/<bundle-id>/Data），
    /// 那里沙盒天然允许读写；宿主 app 不在沙盒里，它等于 appSupportDir。
    ///
    /// 之前它不在 writeTargets 里，而另外两处一个只有只读例外、一个没被验过，
    /// 结果按钮「点得动、什么都不发生」。现在它排第一。
    static var ownDir: String {
        NSHomeDirectory() + "/Library/Application Support/LifeWidget"
    }

    static let cacheName = "items-cache.json"
    static let overrideName = "pick-override.json"

    /// 「随机一条」抽过的下标（按天存的整张表）
    static let randomName = "random-picks.json"

    /// 选条方式 + 顺序模式的起点
    static let settingsName = "settings.json"

    /// 候选目录，按偏好排序并去重。
    ///
    /// 1. ownDir —— 沙盒进程自己的容器，沙盒天然允许，不依赖任何例外，最稳。
    /// 2. appSupportDir —— 靠 temporary-exception.files.home-relative-path.read-write。
    ///    宿主 app（不在沙盒里）写的也是这里，所以两边共用一份，最好读。
    ///
    /// **App Group 那个目录已经剔掉了**（曾经排在第三位）。不是「不该用」，是它在这台
    /// 机器上能把进程直接卡死：`~/Library/Group Containers/group.com.local.lifewidget`
    /// 这个目录存在（stat 正常），但**一列目录内容就无限挂起**，连不沙盒的普通 shell
    /// 都逃不掉。而 dirs() 在每次读和每次写上都会走一遍 —— 于是 `--dump`、`--shuffle`、
    /// 小组件取时间线全都会挂在那里，一次都不返回。
    ///
    /// 这个目录是 ad-hoc 签名（没有 Team ID）下试 App Group 留下的，containerURL
    /// 拿得到路径、containermanagerd 也回 success，但归属对不上真实容器，就成了这么个
    /// 半吊子状态。App Group 在本项目里本来就没用到（见 widget.entitlements 的注释），
    /// 删掉它不改变任何行为，只是把挂起去掉。
    ///
    /// 两处都写、读的时候按修改时间取最新（见 readNewest），所以哪处成了都不影响结果。
    private static func dirs() -> [String] {
        // 只给自检用：把所有状态指到临时目录。自检会写覆盖、切模式、抽几千天的签，
        // 以前它直接写用户的真实文件，跑一次就抹掉了用户当天手动换的那条。
        if let d = ProcessInfo.processInfo.environment["LIFEWIDGET_STATE_DIR"], !d.isEmpty {
            return [d]
        }
        var out: [String] = []
        for d in [ownDir, appSupportDir] where !out.contains(d) {
            out.append(d)
        }
        return out
    }

    /// App Group 容器目录。
    ///
    /// 沙盒里 containerURL 会给真实路径；宿主 app 不在沙盒里，它返回 nil，
    /// 所以自己拼一遍 —— 见下面 groupDir 的注释。
    static var groupContainerDir: String { realHome + "/Library/Group Containers/" + appGroup }

    /// 写入目标：顺序即偏好（先自己家，再真实家目录）。每处都试，尽力而为。
    static func writeTargets(_ name: String) -> [String] {
        dirs().map { $0 + "/" + name }
    }

    /// 读取候选，顺序与写入一致 —— 自己刚写的那份优先读回来。
    static func readCandidates(_ name: String) -> [String] {
        dirs().map { $0 + "/" + name }
    }
}

/// 共享层的日志。用 os.Logger 而不是 print：小组件是后台进程，没人看它的 stdout，
/// 但 `log stream --predicate 'subsystem == "com.local.lifewidget"'` 看得到。
let sharedLog = Logger(subsystem: "com.local.lifewidget", category: "shared")

/// 写一处共享文件，所有候选目录都试。
///
/// 这里的失败**必须**出声。上一版整个函数都是 `try?`，两个目标全写不进去也不报，
/// 表现就只是「按钮点得动、小组件永远不变」，从任何地方都看不出哪里坏了 ——
/// 排查这个 bug 绕的远路，一多半是这层沉默造成的。
private func writeShared(_ data: Data, name: String) {
    let targets = SharedPaths.writeTargets(name)
    var landed: [String] = []

    for path in targets {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            landed.append(path)
            sharedLog.debug("写入成功 \(path, privacy: .public)")
        } catch {
            sharedLog.error("写入失败 \(path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
        }
    }

    // 一个都没落下去 = 读的一方永远看不到这次改动。这条必须是 error 级别。
    if landed.isEmpty {
        sharedLog.error("\(name, privacy: .public) 所有目标都写不进去（试过 \(targets.count) 处），改动不会生效")
    }
}

/// 按**修改时间**取最新的那份，而不是按候选顺序取第一份。
///
/// 「换一条」的覆盖必须走这个：小组件把它写进自己的容器，宿主 app 写进
/// Application Support，两个进程各自只看得到自己那一侧是常有的事。
/// 按顺序取第一份的话，小组件容器里那份昨天的残留会一直压住宿主 app 刚写的新值，
/// 又变成「点了没反应」。
private func readNewest(name: String) -> Data? {
    var best: Data?
    var bestDate = Date.distantPast
    for path in SharedPaths.readCandidates(name) {
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
        // 严格大于：时间相同时保留靠前的那个候选，也就是写入偏好顺序
        if best == nil || date > bestDate {
            best = data
            bestDate = date
        }
    }
    return best
}

// MARK: - 条目

/// 书里的一条建议。字段名对齐 tools/embed.mjs 生成的 JSON，短名是为了压体积。
struct Item: Codable, Hashable {
    var i: Int          // 全书序号
    var c: Int          // 节号
    var ct: String      // 节标题
    var n: Int          // 节内条号
    var t: String       // 标题
    var k: String       // 成本
    var p: String       // 说人话
    var g: String       // 收益（截断版）
    var e: String       // 证据等级 A/B/C
    var q: String       // 证据等级的修饰（「有争议」等），可为空
    var s: [String]     // 来源域名
    var m: String       // 成本标签短码，如「钱0 · 时少 · 收益大」

    /// 「第 1 节第 1 条」
    var refText: String { "第 \(c) 节第 \(n) 条" }

    /// 出处行，空的时候不显示
    var sourceText: String {
        s.isEmpty ? "" : "来源 " + s.prefix(2).joined(separator: "、")
    }
}

struct BookPayload: Codable {
    var title: String
    var repo: String
    var license: String
    var count: Int
    var chapters: [Chapter]
    var items: [Item]

    struct Chapter: Codable, Hashable {
        var num: Int
        var title: String
        var count: Int
    }
}

// MARK: - 缓存

/// 宿主 app 联网拉到的较新书稿。小组件优先用它，没有就用编译进来的。
struct ItemsCache: Codable {
    var payload: BookPayload
    var fetchedAt: Date

    static func write(_ cache: ItemsCache) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(cache) else { return }
        writeShared(data, name: SharedPaths.cacheName)
    }

    static func read() -> ItemsCache? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // 取修改时间最新的那份：宿主 app 拉的新书在 appSupportDir，
        // 小组件容器里可能还留着上一次自己写下的旧副本，按顺序取会读到旧的。
        guard let data = readNewest(name: SharedPaths.cacheName) else { return nil }
        guard let c = try? dec.decode(ItemsCache.self, from: data),
              // 缓存是外来的，残缺就丢掉 —— 半本书比旧书糟
              c.payload.items.count > 100 else { return nil }
        return c
    }

    static func clear() {
        for path in SharedPaths.writeTargets(SharedPaths.cacheName) {
            try? FileManager.default.removeItem(atPath: path)
        }
        PickOverride.clear()
    }
}

// MARK: - 「换一条」的手动覆盖

/// 用户点了小组件上的「换一条」时记下来的选择。
///
/// 每天默认是按日期算出来的那一条（纯函数，同一天处处一致）。用户手动换过之后，
/// 这个覆盖值就顶掉它 —— 但要带上是哪一天的，第二天自动失效，不然「每天一条」就废了。
struct PickOverride: Codable {
    var day: String     // yyyy-MM-dd
    var index: Int

    static func write(day: String, index: Int) {
        guard let data = try? JSONEncoder().encode(PickOverride(day: day, index: index)) else { return }
        writeShared(data, name: SharedPaths.overrideName)
    }

    /// 只认今天的那份；昨天的自动作废。
    static func current(for date: Date, calendar: Calendar = .current) -> Int? {
        guard let data = readNewest(name: SharedPaths.overrideName),
              let o = try? JSONDecoder().decode(PickOverride.self, from: data),
              o.day == DailyPick.dayKey(for: date, calendar: calendar)
        else { return nil }
        return o.index
    }

    /// 清空 = **写一份作废的**，不是删文件。
    ///
    /// 宿主 app 删不到小组件容器里那份（不在它的 writeTargets 里）。删掉自己这份之后，
    /// 小组件容器里的旧覆盖反而成了「最新的一份」，readNewest 会把它捡回来 ——
    /// 切完模式小组件还显示旧的那条，菜单显示新的，两边对不上。
    /// 写一份 day 为空的进去，它的修改时间最新，就压住了所有残留；day 对不上任何日期，等于没有。
    static func clear() {
        write(day: "", index: 0)
    }
}

// MARK: - 选条方式与设置

/// 选条方式。
///
/// 两条路的期待不一样，所以必须分开：
///   - sequential：按书里的顺序往后走，一条接一条。适合真当一本书在读。
///   - random：每条跟前后没关系。适合随便看看。
enum PickMode: String, Codable, CaseIterable {
    case sequential
    case random

    var title: String {
        switch self {
        case .sequential: return "顺序一条"
        case .random:     return "随机一条"
        }
    }
}

/// 宿主 app 和小组件共用的设置。
///
/// **不能用 UserDefaults**：小组件是独立进程、独立 bundle id，它读的
/// UserDefaults.standard 是自己的域，跟宿主 app 的不通。菜单里切了模式，
/// 小组件看不到 —— 表现就是「切了没反应」，跟这个按钮踩过的坑一模一样。
/// 所以跟其它状态一样走共享文件。
struct Settings: Codable {
    var mode: PickMode
    /// 顺序模式的起点（yyyy-MM-dd）。当天是第几天 = 今天 - 这个日期。
    var startDay: String

    static let `default` = Settings(
        mode: .random,
        startDay: DailyPick.dayKey(for: Date()))

    /// 读当前设置。读不到（第一次跑）就用默认值并落盘。
    static func load() -> Settings {
        if let data = readNewest(name: SharedPaths.settingsName),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        let s = Settings.default
        s.save()
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        writeShared(data, name: SharedPaths.settingsName)
    }

    /// 改一个字段并落盘，返回改动后的设置
    @discardableResult
    static func update(_ change: (inout Settings) -> Void) -> Settings {
        var s = load()
        change(&s)
        s.save()
        return s
    }
}

/// 今天是第几条。
///
/// 两种模式共有的硬约束：**同一天之内结果稳定**。系统重排时间线、同时放好几块小组件、
/// appex 被反复冷启动，看到的都必须是同一条。桌面小组件本来就会定时重取时间线，
/// 每次问都换内容的话它会一直跳。
///
///   - sequential：起点到今天是第几天，加上用户「换一条」的偏移。顺序浏览的前提就是
///     可预测 —— 明天一定是今天 +1，所以这里必须真做加法，哈希做不到（散点无法顺移）。
///   - random：当天第一次问的时候抽，抽完存下来，当天不再变。见 RandomPicks。
///
/// 用户点「换一条」后的覆盖走 TodayPick，见 PickOverride。
enum DailyPick {
    /// 按本地日历取「年月日」，跟用户看到的日期一致。
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    /// SplitMix64：把日期这种取值空间很小的输入打散到整个 64 位。
    static func mix(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// 给定日期和条目总数，返回选中条目的下标。
    ///
    /// 注意这个函数**可能有副作用**（随机模式下第一次问某天会抽签并存下来）。
    /// 未来那几天被提前定下来是刻意的，见 RandomPicks 的注释。
    static func index(for date: Date, count: Int, calendar: Calendar = .current) -> Int {
        guard count > 0 else { return 0 }
        switch Settings.load().mode {
        case .sequential:
            return sequentialIndex(for: date, count: count, calendar: calendar)
        case .random:
            return RandomPicks.index(for: date, count: count, calendar: calendar)
        }
    }

    /// 从起点往后数，第几天就是第几条。
    private static func sequentialIndex(for date: Date, count: Int, calendar: Calendar) -> Int {
        guard let start = dayKeyDate(Settings.load().startDay, calendar: calendar) else { return 0 }
        let today = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        // 负天数（系统时间被往回调）也收敛到 0..<count
        return ((days % count) + count) % count
    }

    /// "yyyy-MM-dd" → Date（当天零点）
    static func dayKeyDate(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return calendar.date(from: c)
    }
}

/// 「随机一条」抽过的下标。
///
/// 存**整张表**（每天一个），而不是只存今天那一个。
/// 只存今天的话：时间线一次铺 8 天，为未来那 7 天算下标时会反复覆写同一个位置，
/// 等用户真到那天，看到的是最后一次覆写的结果 —— 而那天原本该是什么已经丢了。
/// 存表还有个好处：预铺未来几天时能一次抽好，之后不管重建多少次时间线都是同一批值。
enum RandomPicks {
    /// dayKey → 下标
    static func load() -> [String: Int] {
        guard let data = readNewest(name: SharedPaths.randomName),
              let m = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return m
    }

    static func save(_ m: [String: Int]) {
        guard let data = try? JSONEncoder().encode(m) else { return }
        writeShared(data, name: SharedPaths.randomName)
    }

    /// 取某天的下标。没抽过就抽一个存下来，之后同一天永远返回同一个。
    static func index(for date: Date, count: Int, calendar: Calendar) -> Int {
        guard count > 0 else { return 0 }
        let key = DailyPick.dayKey(for: date, calendar: calendar)
        var table = load()

        if let v = table[key], (0..<count).contains(v) { return v }

        // 避开前后一周已经定下的。纯随机在 672 条里也会三天内撞上同一条，
        // 用户看到的就是「这不是随机」。只防近处，远处重复是随机的本分。
        let pick = draw(count: count, avoiding: nearby(table, around: date, calendar: calendar))
        table[key] = pick
        save(prune(table, calendar: calendar))
        return pick
    }

    /// 某天前后 7 天内已经定下的下标
    static func nearby(_ table: [String: Int], around date: Date, calendar: Calendar) -> Set<Int> {
        let lo = DailyPick.dayKey(for: calendar.date(byAdding: .day, value: -7, to: date) ?? date, calendar: calendar)
        let hi = DailyPick.dayKey(for: calendar.date(byAdding: .day, value: 7, to: date) ?? date, calendar: calendar)
        return Set(table.filter { $0.key >= lo && $0.key <= hi }.values)
    }

    /// 随机抽一条，尽量不落在 avoiding 里。全被占了（条目极少）就退回纯随机。
    static func draw(count: Int, avoiding: Set<Int>) -> Int {
        let free = (0..<count).filter { !avoiding.contains($0) }
        return free.randomElement() ?? Int.random(in: 0..<count)
    }

    /// 只留昨天及以后的（dayKey 是 yyyy-MM-dd，字典序就是日期序）。
    ///
    /// 为什么要留昨天那一条：连撞检测要读它。只留「今天及以后」的话，
    /// 今天这条抽签时昨天刚被清掉，检测永远不触发 —— 也就是白写。
    /// 更早的没有意义了，过了那天就不会再查。
    private static func prune(_ table: [String: Int], calendar: Calendar) -> [String: Int] {
        guard let y = calendar.date(byAdding: .day, value: -1, to: Date()) else { return table }
        let cutoff = DailyPick.dayKey(for: y, calendar: calendar)
        return table.filter { $0.key >= cutoff }
    }

    /// 写一张空表而不是删文件，理由同 PickOverride.clear()：
    /// 删不到小组件容器里那份，删完它反而成了最新的。
    static func clear() {
        save([:])
    }
}

/// 今天是第几条 —— 在 DailyPick 之上叠加用户的「换一条」覆盖。
///
/// 时间线和宿主 app 都必须走这里，不然点过「换一条」之后两边显示的不是同一条。
enum TodayPick {
    static func index(for date: Date, count: Int, calendar: Calendar = .current) -> Int {
        guard count > 0 else { return 0 }
        // 覆盖带日期，只对「今天」那条匹配得上 —— 未来几天自然拿不到它
        if let o = PickOverride.current(for: date, calendar: calendar), (0..<count).contains(o) {
            return o
        }
        return DailyPick.index(for: date, count: count, calendar: calendar)
    }

    /// 「换一条」：按当前模式换一条并记下来，返回新下标。
    ///
    ///   - 顺序：往后 +1，一路点着往下翻。
    ///   - 随机：随机抽一条。以前这里两种模式都是 +1，随机模式下一点就是书里
    ///     紧挨着的下一条（551 → 552 → 553…），用户看到的就是「随机不对」。
    ///     避开当前这条和近几天表里的，免得点了像没换、或换到明天要出的那条。
    ///
    /// 小组件上的 ShuffleIntent 和 `--shuffle` 命令行都走这里，
    /// 免得两处各写一份、其中一份忘了带日期从而让覆盖永远生效。
    @discardableResult
    static func advance(_ date: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let payload = Book.load(), !payload.items.isEmpty else { return nil }
        let count = payload.items.count
        let current = index(for: date, count: count, calendar: calendar)
        let next: Int
        switch Settings.load().mode {
        case .sequential:
            next = (current + 1) % count
        case .random:
            let near = RandomPicks.nearby(RandomPicks.load(), around: date, calendar: calendar)
            next = RandomPicks.draw(count: count, avoiding: near.union([current]))
        }
        PickOverride.write(day: DailyPick.dayKey(for: date, calendar: calendar), index: next)
        return next
    }

    /// 切换模式时用：清掉两边的当天状态，让新方式从干净状态开始。
    ///
    /// 不清的话，切过来第一天会读到上一种方式留下的覆盖值，位置对不上，
    /// 看起来像是「切了没反应」。
    static func resetForModeChange() {
        PickOverride.clear()
        RandomPicks.clear()
    }
}

// MARK: - 取书

enum Book {
    /// 编译进来的那份。JSON 解析一次就缓存住 —— 时间线每次刷新都重新解析
    /// 六百多条字符串太浪费，小组件的刷新预算本来就紧。
    private static let bundled: BookPayload? = {
        guard let data = BookData.json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BookPayload.self, from: data)
    }()

    /// 有联网缓存就用缓存，否则用内置的。两边都拿不到才返回 nil。
    static func load(preferCache: Bool = true) -> BookPayload? {
        if preferCache, let cache = ItemsCache.read() { return cache.payload }
        return bundled
    }

    /// 今天该显示的那一条。
    static func today(_ date: Date = Date(), preferCache: Bool = true) -> Item? {
        guard let payload = load(preferCache: preferCache), !payload.items.isEmpty else { return nil }
        let idx = TodayPick.index(for: date, count: payload.items.count)
        return payload.items[min(idx, payload.items.count - 1)]
    }

    /// 数据是不是编译时那份（宿主 app 用它判断要不要提示「可以联网更新」）。
    static var cacheIsNewer: Bool { ItemsCache.read() != nil }
}
