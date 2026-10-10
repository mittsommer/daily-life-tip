import SwiftUI
import WidgetKit

// 手机版的四个页面：今天、翻阅、小组件、设置。
//
// 这里刻意不用 iOS 专有的 API（NavigationStack 之外基本没有），因为要在 macOS 上编译出来
// 跑预览。换成真 iOS 工程时，这些视图可以原样搬过去。

enum PhoneTab: String, CaseIterable, Identifiable {
    case today, browse, widget, settings
    var id: String { rawValue }
    var key: String { rawValue }

    var title: String {
        switch self {
        case .today:    return "今天"
        case .browse:   return "翻阅"
        case .widget:   return "小组件"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .today:    return "sun.max"
        case .browse:   return "book"
        case .widget:   return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

/// 手机里的根视图：内容 + 底部标签栏
struct PhoneRoot: View {
    @State private var tab: PhoneTab
    /// 改这个值让「今天」那条重算（换一条、切模式之后）
    @State private var reloadToken = 0

    init(initialTab: PhoneTab = .today) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch tab {
                case .today:    TodayTab(token: reloadToken).id(reloadToken)
                case .browse:   BrowseTab()
                case .widget:   WidgetTab(token: reloadToken).id(reloadToken)
                case .settings: SettingsTab(onChange: { reloadToken += 1 }).id(reloadToken)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
        // 真 iPhone 上系统会让出状态栏和 Home 条；这里是画出来的手机，要自己让
        .padding(.top, PhoneMetrics.safeTop)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PhoneTab.allCases) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 19, weight: .regular))
                        Text(t.title).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(tab == t ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, PhoneMetrics.safeBottom)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 今天

struct TodayTab: View {
    var token: Int
    /// 直接取，不走 onAppear —— 离屏渲染不会触发 onAppear，那样截出来是空白页（踩过）
    @State private var item: Item? = Book.today()
    @State private var justCopied = false

    var body: some View {
        PageBody {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(DailyPick.dayKey(for: Date()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let item {
                        Text(item.refText).font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }

                if let item {
                    Text(item.t)
                        .font(.system(size: 27, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        EvidenceBadge(grade: item.e, qualifier: item.q)
                        if !item.m.isEmpty {
                            Text(item.m).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }

                    Section2("说人话", item.p, primary: true)
                    if !item.g.isEmpty { Section2("收益", item.g) }
                    if !item.k.isEmpty { Section2("成本", item.k) }
                    if !item.s.isEmpty {
                        Section2("来源", item.s.joined(separator: "\n"))
                    }

                    Text("《高性价比人生指南》\(item.refText) · CC BY 4.0")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)

                    actions(item)
                } else {
                    Text("数据没读到").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ item: Item) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                BigButton("换一条", "arrow.triangle.2.circlepath") {
                    TodayPick.advance()
                    self.item = Book.today()
                }
                BigButton(justCopied ? "已复制" : "复制", justCopied ? "checkmark" : "doc.on.doc") {
                    copyText(item)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { justCopied = false }
                }
                BigButton("分享", "square.and.arrow.up") {
                    share(item)
                }
            }
        }
        .padding(.top, 4)
    }

    /// 手机上「复制」和「分享」是两件事：前者直接进剪贴板，后者走系统分享面板。
    /// 预览版里分享面板用 macOS 的 NSSharingServicePicker 顶替，逻辑一样。
    private func copyText(_ item: Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("""
        \(item.t)

        \(item.p)

        成本：\(item.k)
        收益：\(item.g)
        证据等级：\(item.e)\(item.q.isEmpty ? "" : "（\(item.q)）")
        \(item.sourceText)

        —— 《高性价比人生指南》\(item.refText)
        """, forType: .string)
    }

    private func share(_ item: Item) {
        guard let file = ShareCard.file(for: item, dark: PhoneAppearance.isDark) else { return }
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        NSSharingServicePicker(items: [file])
            .show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                  of: view, preferredEdge: .minY)
    }
}

/// 是不是在离屏渲染。渲染时交互控件要换成静态外观。
enum PhoneRenderMode {
    static let isRendering = CommandLine.arguments.contains("--render")
}

/// 页面主体。窗口里是可滚动的，离屏渲染时是普通容器 ——
/// ImageRenderer 不量 ScrollView 的高度，内容整块塌掉，截出来是白页（踩过）。
struct PageBody<Content: View>: View {
    var content: () -> Content

    var body: some View {
        if PhoneRenderMode.isRendering {
            // 固定成可用的那块大小、顶部对齐再裁掉 —— 内容比屏幕高时，
            // 弹性 frame 会把它居中，截出来是从列表中间开始的（踩过）
            GeometryReader { geo in
                content()
                    .frame(width: geo.size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
            }
        } else {
            ScrollView { content() }
        }
    }
}

/// 手机版看不到 NSApp.effectiveAppearance 在渲染时的取值，统一走这里
enum PhoneAppearance {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - 翻阅

struct BrowseTab: View {
    @State private var query = ""
    @State private var payload: BookPayload? = Book.load()

    private var groups: [(chapter: BookPayload.Chapter, items: [Item])] {
        guard let payload else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        return payload.chapters.compactMap { ch in
            let all = payload.items.filter { $0.c == ch.num }
            let hit = q.isEmpty ? all : all.filter { $0.t.contains(q) || $0.p.contains(q) }
            return hit.isEmpty ? nil : (ch, hit)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 14))
                // 交互控件在离屏渲染里画不出来（会变成一条黄条），渲染时用静态文字顶替
                if PhoneRenderMode.isRendering {
                    Text(query.isEmpty ? "搜标题或内容" : query)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    TextField("搜标题或内容", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            PageBody {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.chapter.num) { group in
                        Section {
                            ForEach(group.items, id: \.i) { it in
                                row(it)
                            }
                        } header: {
                            Text("第 \(group.chapter.num) 节 · \(group.chapter.title)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(.bar)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func row(_ it: Item) -> some View {
        let isToday = TodayPick.index(for: Date(), count: payload?.items.count ?? 1) == it.i
        return HStack(alignment: .top, spacing: 10) {
            Text("\(it.n)").font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(it.t).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                Text(it.p).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if isToday {
                Text("今天").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            } else {
                Text(it.e).font(.system(size: 11, weight: .semibold)).foregroundStyle(evidenceColor(it.e))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Divider().padding(.leading, 48) }
    }
}

// MARK: - 小组件预览

/// 手机桌面上的小组件长什么样。这里的视图就是 Mac 版小组件那份（WidgetViews.swift），
/// 只是套了个手机桌面的背景。
struct WidgetTab: View {
    var token: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        PageBody {
            VStack(alignment: .leading, spacing: 18) {
                Text("手机桌面")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)

                if let item = Book.today() {
                    VStack(spacing: 16) {
                        widget(item, .systemMedium, CGSize(width: 338, height: 158))
                        HStack(spacing: 16) {
                            widget(item, .systemSmall, CGSize(width: 158, height: 158))
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                                .frame(width: 158, height: 158)
                                .overlay(Text("其他 app").font(.system(size: 11)).foregroundStyle(.tertiary))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Text("小组件上的两个按钮：分享和换一条。点分享会打开 app 并把这条做成图片，点换一条直接换。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    private func widget(_ item: Item, _ family: WidgetFamily, _ size: CGSize) -> some View {
        LifeWidgetView(entry: DailyEntry(date: Date(), item: item, isToday: true), familyOverride: family)
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.17) : Color.white))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: 10, y: 4)
    }
}

// MARK: - 设置

struct SettingsTab: View {
    var onChange: () -> Void
    @State private var mode: PickMode = Settings.load().mode
    @State private var count = Book.load()?.items.count ?? 0
    @State private var index = Book.load().map { TodayPick.index(for: Date(), count: $0.items.count) } ?? 0

    var body: some View {
        PageBody {
            VStack(alignment: .leading, spacing: 22) {
                group("选条方式") {
                    ForEach(PickMode.allCases, id: \.self) { m in
                        Button {
                            guard m != mode else { return }
                            Settings.update { $0.mode = m }
                            TodayPick.resetForModeChange()
                            mode = m
                            refresh()
                            onChange()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).font(.system(size: 16))
                                        .foregroundStyle(.primary)
                                    Text(m == .sequential ? "从第 1 条起，每天往后一条，按顺序读完" : "每天随机一条，一周内不重复")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode == m {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }

                if mode == .sequential {
                    group("进度") {
                        HStack {
                            Text("第 \(index + 1) / \(count) 条").font(.system(size: 15))
                            Spacer()
                            Button("从头开始") { restart() }
                                .buttonStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 8)
                    }
                }

                group("关于") {
                    infoRow("条目数", "\(count) 条")
                    infoRow("数据来源", "《高性价比人生指南》")
                    infoRow("协议", "代码 MIT · 正文 CC BY 4.0")
                    infoRow("项目地址", Project.repo)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("这是手机版预览").font(.system(size: 12, weight: .semibold))
                    Text("界面和逻辑按 iPhone 尺寸跑在电脑上。要装到真机、要用手机桌面小组件，需要 Apple 开发者账号和 Xcode。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        mode = Settings.load().mode
        count = Book.load()?.items.count ?? 0
        index = count > 0 ? TodayPick.index(for: Date(), count: count) : 0
    }

    /// 「从头开始」：起点设成「今天减当前下标」，今天这条不动，明天起往后走。
    private func restart() {
        guard count > 0 else { return }
        let start = Calendar.current.date(byAdding: .day, value: -index, to: Date()) ?? Date()
        Settings.update { $0.startDay = DailyPick.dayKey(for: start) }
        TodayPick.resetForModeChange()
        refresh()
        onChange()
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
    }

    private func infoRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.system(size: 15))
            Spacer()
            Text(value).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - 小零件

struct Section2: View {
    var name: String
    var text: String
    var primary = false

    init(_ name: String, _ text: String, primary: Bool = false) {
        self.name = name; self.text = text; self.primary = primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: primary ? 17 : 14))
                .foregroundStyle(primary ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EvidenceBadge: View {
    var grade: String
    var qualifier: String

    var body: some View {
        HStack(spacing: 4) {
            Text("证据 \(grade)").font(.system(size: 12, weight: .semibold))
            if !qualifier.isEmpty {
                Text(qualifier).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(evidenceColor(grade))
    }
}

struct BigButton: View {
    var title: String
    var icon: String
    var action: () -> Void

    init(_ title: String, _ icon: String, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}

func evidenceColor(_ grade: String) -> Color {
    switch grade {
    case "A": return .green
    case "B": return .orange
    default:  return .secondary
    }
}
