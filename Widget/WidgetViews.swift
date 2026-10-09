import SwiftUI
import WidgetKit
import AppIntents

// 小组件的界面，以及它上面那个「换一条」按钮。
//
// 单独成文件是因为宿主 app 也要编译它：菜单里「分享今天这条」生成的图片
// 就是用这同一份视图画的（见 Sources/ShareCard.swift），保证分享出去的跟桌面上的长得一样。
// 时间线和注册留在 LifeWidget.swift，那些只属于 appex。

// MARK: - 换一条

/// 小组件上那个「换一条」按钮。
///
/// 用 AppIntent 而不是普通的 Button 闭包：macOS 14 起小组件是只读快照，
/// 只有 AppIntent 能在 appex 进程里跑代码。它跑完的结果只能通过共享文件
/// 影响下一次时间线，所以这里把选择写进 App Group，再请系统重取。
struct ShuffleIntent: AppIntent {
    static var title: LocalizedStringResource = "换一条"
    static var description = IntentDescription("跳过今天这条，看下一条")

    func perform() async throws -> some IntentResult {
        // 逻辑在 TodayPick.advance（Shared.swift），跟 `--shuffle` 共用一个实现
        TodayPick.advance()
        // 只重取本小组件，不动系统里其他家的
        WidgetCenter.shared.reloadTimelines(ofKind: "LifeWidget")
        return .result()
    }
}

// MARK: - 条目

struct DailyEntry: TimelineEntry {
    var date: Date
    var item: Item?
    /// 建时间线那一刻，这条是不是「今天」。只给自检打印用 ——
    /// **视图别拿它做判断**：过了零点，原来的「明天」被显示出来时它还是 false。
    var isToday: Bool
}

// MARK: - 小组件

struct LifeWidgetView: View {
    @Environment(\.widgetFamily) private var envFamily
    var entry: DailyEntry
    /// 只给 tools/render-screenshot.swift 用：widgetFamily 是只读环境值，
    /// 离屏渲染 README 截图时没法从外面设，只能走这里。小组件里不传。
    var familyOverride: WidgetFamily? = nil
    /// 右上角的分享 / 换一条按钮。生成分享图片时关掉 —— 图片里的按钮点不了，只是噪音。
    var showsControls = true

    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        Group {
            if let item = entry.item {
                switch family {
                case .systemSmall:  small(item)
                case .systemLarge:  large(item)
                default:            medium(item)
                }
            } else {
                fallback
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text("数据没读到").font(.system(size: 12, weight: .medium))
            Text("重启一下宿主应用").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 公共小块

    private var header: some View {
        HStack(spacing: 4) {
            Text(BookData.bookTitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            // 按钮**无条件**显示。以前按 entry.isToday 决定，但那是建时间线那一刻写死的：
            // 一次铺 8 天只有第 0 条是 true，过了零点系统切到第 1 条，按钮就没了，
            // 而 .atEnd 策略下系统 7 天内都不会来重建 —— 表现是「隔天按钮消失」。
            // 任何一条被显示出来的时候它就是今天；ShuffleIntent 也是按点击时的
            // Date() 算的，跟这条是哪天铺的无关。
            if showsControls {
                // 小尺寸不放分享：系统把小尺寸整块当成一个点击区域，里面的 Link 不保证点得到，
                // 位置也挤。小尺寸要分享走菜单栏。
                if family != .systemSmall { shareButton }
                shuffleButton
            }
        }
    }

    /// 分享：一个小圆圈里的分享图标。
    ///
    /// 小组件进程里弹不出分享面板、也碰不到剪贴板（沙盒 + 后台进程），
    /// 所以这里只是个链接：lifewidget://share 把宿主 app 叫起来，由它生成图片、
    /// 复制到剪贴板、弹分享面板（见 main.swift 的 application(_:open:)）。
    @ViewBuilder
    private var shareButton: some View {
        // 离屏渲染（README 截图）时画不出 Link，会变成一个黄色禁止符号的占位图，
        // 那时只画图标。familyOverride 有值就说明是离屏渲染（小组件里不传它）。
        if familyOverride != nil {
            circleIcon("square.and.arrow.up")
        } else {
            Link(destination: URL(string: "lifewidget://share")!) {
                circleIcon("square.and.arrow.up")
            }
            .help("分享这条")
        }
    }

    /// 换一条：一个小圆圈刷新标记
    private var shuffleButton: some View {
        Button(intent: ShuffleIntent()) {
            circleIcon("arrow.triangle.2.circlepath")
        }
        .buttonStyle(.plain)
        .help("换一条")
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 17, height: 17)
            .background(Circle().fill(Color.primary.opacity(0.09)))
    }

    /// 证据等级徽章：A 用实心，B/C 用描边。有争议的加个点。
    private func badge(_ item: Item, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text("证据 \(item.e)")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(evidenceTint(item.e))
            if !item.q.isEmpty {
                Text(item.q)
                    .font(.system(size: size - 1))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func evidenceTint(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B": return .orange
        default:  return .secondary
        }
    }

    /// 出处 + 第几节第几条，小组件底部那行
    private func footer(_ item: Item, size: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(item.refText)
            if !item.sourceText.isEmpty {
                Text("·").foregroundStyle(.quaternary)
                Text(item.sourceText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: size))
        .foregroundStyle(.tertiary)
    }

    // MARK: 小尺寸 —— 只够放标题

    private func small(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 5)

            // 标题中位 29 字、最长 76 字，小尺寸一行约 10 字，所以行数是关键：
            //   ≤30 字（58%）→ 3 行够
            //   31–39 字（27%）→ 3 行 + 缩到 0.8 够
            //   >39 字（15%）→ 3 行放不下，加到 4 行。
            // 小尺寸的全部信息就是这句标题，被截尾等于这条废掉 ——
            // 而且长标题的后半句常常才是关键（「…每年最多 12000 元能税前扣掉；
            // 不交个税或税率只有 3% 的人开了不划算」，重点在后半句）。
            Text(item.t)
                .font(.system(size: item.t.count > 34 ? 13 : 15, weight: .semibold))
                .lineLimit(item.t.count > 39 ? 4 : 3)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 5)
            if !item.m.isEmpty {
                Text(item.m)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                badge(item, size: 9)
                Spacer(minLength: 0)
                Text(item.refText).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 中尺寸 —— 主力形态

    private func medium(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)

            Text(item.t)
                .font(.system(size: item.t.count > 34 ? 14 : 16, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            if !item.p.isEmpty {
                Text(item.p)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 4)
            }

            Spacer(minLength: 4)
            HStack(spacing: 6) {
                badge(item, size: 9)
                if !item.m.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                    Text(item.m).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            footer(item, size: 9).padding(.top, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 大尺寸 —— 铺开

    private func large(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6)

            Text(item.t)
                .font(.system(size: item.t.count > 34 ? 15 : 18, weight: .semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.85)

            if !item.m.isEmpty {
                Text(item.m)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }

            if !item.p.isEmpty {
                labelled("说人话", item.p, limit: 5)
            }
            if !item.g.isEmpty {
                labelled("收益", item.g, limit: 5)
            }
            if !item.k.isEmpty {
                labelled("成本", item.k, limit: 3)
            }

            Spacer(minLength: 6)
            HStack(spacing: 6) {
                badge(item, size: 10)
                Spacer(minLength: 0)
            }
            footer(item, size: 9).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labelled(_ name: String, _ text: String, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(name == "说人话" ? .primary : .secondary)
                .lineLimit(limit)
        }
        .padding(.top, 6)
    }
}
