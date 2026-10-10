import AppKit
import SwiftUI
import WidgetKit

// LifeWidget 宿主 app。
//
// 它本身是菜单栏常驻（LSUIElement，不进 Dock）。存在的理由有三个：
//   1. 系统小组件是只读的，得有个地方看全文、看来源
//   2. 联网更新书稿（WidgetKit 的时间线预算做不了这个）
//   3. 不跑它，小组件照样显示 —— 数据编译在二进制里，这一点跟 sc-usage-widget 不同

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var updating = false
    /// 查到的 app 新版本（不是书稿）。有值时菜单里那项变成「更新到 x.y.z」
    private var appUpdate: AppUpdater.Release?
    private var installingUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --dump：不起界面，直接把今天的条目打到终端
        if CommandLine.arguments.contains("--dump") {
            dumpToday()
            NSApp.terminate(nil)
            return
        }

        // --shuffle：走一遍小组件上「换一条」按钮的同一条逻辑，然后打印结果。
        // 存在的理由：按钮的点击分发我验证不了（要人手点），但点击之后的实际行为
        // 就是这个函数。跑一遍就知道点下去会不会真的换。
        if CommandLine.arguments.contains("--shuffle") {
            guard let idx = TodayPick.advance() else { print("没有数据"); NSApp.terminate(nil); return }
            dumpToday()
            print("\n→ 已顺移到下标 \(idx)（等同于点一次小组件上的刷新标记）")
            NSApp.terminate(nil)
            return
        }

        // --clear-override：清掉「换一条」的覆盖，回到按模式算的那条
        if CommandLine.arguments.contains("--clear-override") {
            PickOverride.clear()
            print("已清空「换一条」的覆盖")
            dumpToday()
            NSApp.terminate(nil)
            return
        }

        // --mode sequential|random：命令行切换选条方式，跟菜单里那个是同一套状态。
        // 存在的理由跟 --shuffle 一样：菜单要人手点，这个能在脚本里验。
        if let i = CommandLine.arguments.firstIndex(of: "--mode") {
            guard CommandLine.arguments.count > i + 1,
                  let mode = PickMode(rawValue: CommandLine.arguments[i + 1]) else {
                print("用法：--mode sequential|random")
                NSApp.terminate(nil)
                return
            }
            Settings.update { $0.mode = mode }
            TodayPick.resetForModeChange()
            print("已切到「\(mode.title)」")
            dumpToday()
            NSApp.terminate(nil)
            return
        }

        // --check-update / --install-update：查 / 装 app 新版本，不起界面。
        // 存在的理由跟 --shuffle 一样：菜单要人手点，这个能在脚本里验整条更新流程。
        // --install-update 不会重新打开 app，只在本进程退出后把文件换掉。
        if CommandLine.arguments.contains("--check-update") || CommandLine.arguments.contains("--install-update") {
            switch AppUpdater.check() {
            case .available(let r):
                print("当前 \(AppUpdater.currentVersion)，有新版本 \(r.version)：\(r.dmgURL.absoluteString)")
                if CommandLine.arguments.contains("--install-update") {
                    do {
                        try AppUpdater.install(r, relaunch: false)
                        print("新版本已暂存，本进程退出后替换")
                    } catch {
                        print("更新失败：\(error.localizedDescription)")
                    }
                }
            case .upToDate(let latest):
                print("已经是最新版（当前 \(AppUpdater.currentVersion)，最新发布 \(latest)）")
            case .notConfigured:
                print("没设置发布仓库（构建时用 UPDATE_REPO=用户名/仓库名）")
            case .failed(let why):
                print("检查失败：\(why)")
            }
            NSApp.terminate(nil)
            return
        }

        // --update：跑一遍「联网更新书稿」，把结果打出来。
        // 存在的理由跟 --shuffle 一样：菜单要人手点，这个能在脚本里验。
        if CommandLine.arguments.contains("--update") {
            switch RemoteBook.updateIfNeeded(force: true) {
            case .updated(let commit, let count):
                print("✅ 更新成功：\(count) 条 @ \(commit)")
            case .unchanged:
                print("已经是最新")
            case .failed(let why):
                print("❌ 更新失败：\(why)")
            }
            dumpToday()
            NSApp.terminate(nil)
            return
        }

        // --share-image <路径>：把今天这条的分享图写到文件（加 --dark 画深色）。
        // 存在的理由跟 --shuffle 一样：分享面板要人手点，图片本身能在脚本里验。
        if let i = CommandLine.arguments.firstIndex(of: "--share-image") {
            let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "share.png"
            let dark = CommandLine.arguments.contains("--dark")
            if let item = Book.today(), let data = ShareCard.png(for: item, dark: dark),
               (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                print("已写入 \(path)：\(item.t)")
            } else {
                print("生成失败")
            }
            NSApp.terminate(nil)
            return
        }

        // --selftest <book目录>：比对两套解析器
        if let idx = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.count > idx + 1
                ? CommandLine.arguments[idx + 1]
                : FileManager.default.currentDirectoryPath + "/book"
            let ok = RemoteBook.selfTest(bookDir: dir)
            NSApp.terminate(ok ? nil : nil)
        }

        // 直接在 dmg 里双击打开的：小组件会注册到 /Volumes/… 下面，
        // 一弹出 dmg 那个路径就没了，小组件随之消失。必须先拖进「应用程序」。
        if Bundle.main.bundlePath.hasPrefix("/Volumes/") {
            let alert = NSAlert()
            alert.messageText = "请先把「LifeWidget」拖进「应用程序」文件夹"
            alert.informativeText = "直接从安装盘里打开的话，弹出安装盘后桌面小组件就会消失。\n拖过去之后，从「应用程序」里打开它。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        SelfRegister.widget()

        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.async { [weak self] in self?.showDetail(nil) }
        }

        // 一天最多自动查一次有没有新版。失败无所谓，内置数据照常工作。
        if UserDefaults.standard.object(forKey: "lastAutoCheck") == nil
            || Date().timeIntervalSince(UserDefaults.standard.object(forKey: "lastAutoCheck") as? Date ?? .distantPast) > 86400 {
            UserDefaults.standard.set(Date(), forKey: "lastAutoCheck")
            runUpdate(force: false, quiet: true)
        }

        // app 新版本：启动时查一次，之后每天查一次（菜单栏 app 一挂就是几周）。
        // 安静地查，查到了只在菜单里亮出来，不弹窗打断人。
        checkAppUpdate(quiet: true)
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            // 定时器挂在主线程的 run loop 上，回调本来就在主线程
            MainActor.assumeIsolated { self?.checkAppUpdate(quiet: true) }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = statusImage()
        item.button?.imagePosition = .imageLeading
        item.button?.title = " 今日一条"
        item.menu = buildMenu()
        statusItem = item
    }

    /// 菜单栏那个小图标：画一本合着的书
    private func statusImage() -> NSImage {
        let size = NSSize(width: 16, height: 15)
        let img = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 11, height: 12),
                                    xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1.4
            NSColor.black.setStroke()
            path.stroke()
            // 书脊
            let spine = NSBezierPath()
            spine.move(to: NSPoint(x: 5.5, y: 1.5))
            spine.line(to: NSPoint(x: 5.5, y: 13.5))
            spine.lineWidth = 1.1
            NSColor.black.setStroke()
            spine.stroke()
            return true
        }
        img.isTemplate = true   // 跟随菜单栏明暗
        return img
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 最上面：今天的条目摘要，点开看全文
        if let item = Book.today() {
            let head = NSMenuItem(title: truncate(item.t, 34), action: #selector(showDetail(_:)), keyEquivalent: "")
            head.target = self
            head.toolTip = item.refText
            menu.addItem(head)
            menu.addItem(.separator())
        }

        let detail = NSMenuItem(title: "看今天的全文…", action: #selector(showDetail(_:)), keyEquivalent: "d")
        detail.target = self
        menu.addItem(detail)

        let copy = NSMenuItem(title: "复制今天这条（文字）", action: #selector(copyToday(_:)), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)

        let copyImage = NSMenuItem(title: "复制今天这条（图片）", action: #selector(copyTodayImage(_:)), keyEquivalent: "C")
        copyImage.target = self
        menu.addItem(copyImage)

        let share = NSMenuItem(title: "分享今天这条…", action: #selector(shareToday(_:)), keyEquivalent: "s")
        share.target = self
        menu.addItem(share)

        menu.addItem(.separator())

        // 选条方式。放在这里而不是设置里，是因为它是个会来回切的偏好 ——
        // 想读书的时候按顺序，随便看看的时候随机。
        let settings = Settings.load()
        let modeItem = NSMenuItem(title: "选条方式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in PickMode.allCases {
            let mi = NSMenuItem(title: mode.title, action: #selector(setMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = (mode == settings.mode) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 顺序模式才有进度可言，随机模式显示这个没有意义
        if settings.mode == .sequential {
            let count = Book.load()?.items.count ?? 0
            if count > 0 {
                let idx = TodayPick.index(for: Date(), count: count)
                let p = NSMenuItem(title: "进度：第 \(idx + 1) / \(count) 条", action: nil, keyEquivalent: "")
                p.isEnabled = false
                menu.addItem(p)
            }
            let restart = NSMenuItem(title: "从头开始", action: #selector(restartSequence(_:)), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
        }

        let reroll = NSMenuItem(title: "今天换一条", action: #selector(rerollToday(_:)), keyEquivalent: "n")
        reroll.target = self
        menu.addItem(reroll)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开在线检索页", action: #selector(openSite(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let repo = NSMenuItem(title: "打开 GitHub 仓库", action: #selector(openRepo(_:)), keyEquivalent: "")
        repo.target = self
        menu.addItem(repo)

        menu.addItem(.separator())

        let update = NSMenuItem(title: updating ? "正在更新…" : "联网更新书稿", action: #selector(updateNow(_:)), keyEquivalent: "r")
        update.target = self
        update.isEnabled = !updating
        update.tag = 100
        menu.addItem(update)

        let reset = NSMenuItem(title: "清空缓存，回到内置数据", action: #selector(resetCache(_:)), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = Book.cacheIsNewer
        menu.addItem(reset)

        menu.addItem(.separator())

        // app 本身的新版本（跟上面的「书稿」是两回事）
        let appUpd: NSMenuItem
        if installingUpdate {
            appUpd = NSMenuItem(title: "正在下载新版本…", action: nil, keyEquivalent: "")
        } else if let r = appUpdate {
            appUpd = NSMenuItem(title: "更新到 \(r.version)…", action: #selector(checkAppUpdateNow(_:)), keyEquivalent: "")
        } else if AppUpdater.latestURL == nil {
            // 没配发布仓库：action 为 nil，菜单自动置灰
            appUpd = NSMenuItem(title: "检查新版本（未设置发布地址）", action: nil, keyEquivalent: "")
        } else {
            appUpd = NSMenuItem(title: "检查新版本…（当前 \(AppUpdater.currentVersion)）",
                                action: #selector(checkAppUpdateNow(_:)), keyEquivalent: "")
        }
        appUpd.target = self
        menu.addItem(appUpd)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "开机启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    // MARK: 动作

    @objc private func showDetail(_ sender: Any?) {
        guard let item = Book.today() else { return }

        if let w = window {
            w.contentView = NSHostingView(rootView: DetailView(item: item, onClose: { [weak self] in self?.window?.close() }))
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "今日一条 · \(item.refText)"
        w.titlebarAppearsTransparent = true
        w.contentView = NSHostingView(rootView: DetailView(item: item, onClose: { [weak self] in self?.window?.close() }))
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    @objc private func copyToday(_ sender: Any?) {
        guard let item = Book.today() else { return }
        let text = """
        \(item.t)

        \(item.p)

        成本：\(item.k)
        收益：\(item.g)
        证据等级：\(item.e)\(item.q.isEmpty ? "" : "（\(item.q)）")
        \(item.sourceText)

        —— 《高性价比人生指南》\(item.refText)
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: 分享

    /// 跟随系统外观画分享图：深色模式下分享出去的也是深色卡片
    private var prefersDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    @objc private func copyTodayImage(_ sender: Any?) {
        guard let item = Book.today(), let img = ShareCard.image(for: item, dark: prefersDark) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        flashStatus("已复制图片")
    }

    @objc private func shareToday(_ sender: Any?) {
        guard let item = Book.today(), let file = ShareCard.file(for: item, dark: prefersDark) else { return }
        guard let anchor = statusItem?.button else { return }
        // 菜单栏 app 不在前台，不激活的话分享面板一闪就没
        NSApp.activate(ignoringOtherApps: true)
        NSSharingServicePicker(items: [file]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// 小组件上的分享按钮：lifewidget://share。
    /// 先复制图片（最常见的用法是直接粘贴进聊天窗口），再弹分享面板给想发 AirDrop、邮件的。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "lifewidget" && $0.host == "share" }) else { return }
        copyTodayImage(nil)
        shareToday(nil)
    }

    /// 菜单栏标题临时换成一句提示，两秒后恢复。比弹窗轻 —— 复制这种小事不值得打断人。
    private func flashStatus(_ text: String) {
        guard let button = statusItem?.button else { return }
        let original = appUpdate == nil ? " 今日一条" : " 今日一条 •"
        button.title = " " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { button.title = original }
    }

    @objc private func openSite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://eternity4719.github.io/HowToLiveBetter/")!)
    }

    @objc private func openRepo(_ sender: Any?) {
        NSWorkspace.shared.open(BookData.repoURL)
    }

    @objc private func updateNow(_ sender: Any?) {
        runUpdate(force: true, quiet: false)
    }

    @objc private func resetCache(_ sender: Any?) {
        ItemsCache.clear()
        UserDefaults.standard.removeObject(forKey: "lastCommit")
        refreshMenu()
        WidgetRefresher.reload()
        notify("已回到内置数据")
    }

    @objc private func toggleLogin(_ sender: Any?) {
        LoginItem.toggle()
        refreshMenu()
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PickMode(rawValue: raw) else { return }
        guard mode != Settings.load().mode else { return }

        Settings.update { $0.mode = mode }
        // 切换时两边的当天状态都要清掉：不清的话「顺序」切过来会读到随机留下的下标，
        // 位置对不上，看起来像是切了没反应。
        TodayPick.resetForModeChange()

        refreshMenu()
        WidgetRefresher.reload()
        notify("已切到「\(mode.title)」")
    }

    @objc private func rerollToday(_ sender: Any?) {
        guard TodayPick.advance() != nil else { return }
        refreshMenu()
        WidgetRefresher.reload()
    }

    @objc private func restartSequence(_ sender: Any?) {
        let count = Book.load()?.items.count ?? 0
        guard count > 0 else { return }
        let idx = TodayPick.index(for: Date(), count: count)

        // 起点设成「今天 - 当前下标」，这样今天算出来还是原来那条，
        // 明天起才往后走。直接把起点设成今天的话今天会突然跳回第 1 条，
        // 等于顺手改掉了用户正在看的这条。
        let start = Calendar.current.date(byAdding: .day, value: -idx, to: Date()) ?? Date()
        Settings.update { $0.startDay = DailyPick.dayKey(for: start) }
        TodayPick.resetForModeChange()

        refreshMenu()
        WidgetRefresher.reload()
        notify("今天仍是第 \(idx + 1) 条，明天起按顺序往后走")
    }

    // MARK: app 新版本

    @objc private func checkAppUpdateNow(_ sender: Any?) {
        if let r = appUpdate { confirmAppUpdate(r); return }
        checkAppUpdate(quiet: false)
    }

    private func checkAppUpdate(quiet: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = AppUpdater.check()
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .available(let r):
                    self.appUpdate = r
                    // 菜单栏标题上加个点，不点开菜单也知道有新版
                    self.statusItem?.button?.title = " 今日一条 •"
                    self.refreshMenu()
                    if !quiet { self.confirmAppUpdate(r) }
                case .upToDate:
                    if !quiet { self.notify("已经是最新版（\(AppUpdater.currentVersion)）") }
                case .notConfigured:
                    break
                case .failed(let why):
                    if !quiet { self.notify("检查新版本失败：\(why)") }
                }
            }
        }
    }

    private func confirmAppUpdate(_ r: AppUpdater.Release) {
        // 菜单栏 app 不在前台，不激活的话弹窗会躲在别的窗口后面
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "有新版本 \(r.version)"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "当前是 \(AppUpdater.currentVersion)。"
            + (notes.isEmpty ? "" : "\n\n" + notes)
            + "\n\n更新时会自动退出再重新打开，选条方式和今天这条都会保留。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "以后再说")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installingUpdate = true
        refreshMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do { try AppUpdater.install(r) } catch { failure = error }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let failure else {
                    // 替换脚本在等这个进程退出
                    NSApp.terminate(nil)
                    return
                }
                self.installingUpdate = false
                self.refreshMenu()
                let a = NSAlert()
                a.messageText = "更新失败"
                a.informativeText = failure.localizedDescription + "\n\n原来的版本没动，可以继续用。"
                if r.pageURL != nil { a.addButton(withTitle: "去下载页手动更新") }
                a.addButton(withTitle: "好")
                if a.runModal() == .alertFirstButtonReturn, let page = r.pageURL {
                    NSWorkspace.shared.open(page)
                }
            }
        }
    }

    // MARK: 更新

    private func runUpdate(force: Bool, quiet: Bool) {
        guard !updating else { return }
        updating = true
        refreshMenu()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = RemoteBook.updateIfNeeded(force: force)
            DispatchQueue.main.async {
                guard let self else { return }
                self.updating = false
                switch result {
                case .updated(let commit, let count):
                    self.refreshMenu()
                    WidgetRefresher.reload()
                    if !quiet { self.notify("已更新到 \(count) 条（\(commit)）") }
                case .unchanged:
                    self.refreshMenu()
                    if !quiet { self.notify("已经是最新版") }
                case .failed(let why):
                    self.refreshMenu()
                    if !quiet { self.notify("更新失败：\(why)\n继续用内置数据") }
                }
            }
        }
    }

    private func notify(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "LifeWidget"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // MARK: 调试出口

    private func dumpToday() {
        guard let item = Book.today() else { print("没有数据"); return }
        let source: String
        if let cache = ItemsCache.read() {
            source = "联网缓存（\(cache.payload.items.count) 条，\(cache.fetchedAt)）"
        } else {
            source = "内置快照（\(BookData.itemCount) 条）"
        }
        // 下标必须走 TodayPick（带用户覆盖），跟上面的 Book.today() 同一条路。
        // 用 DailyPick 的话，点过「换一条」之后打印的下标和正文会对不上。
        let count = Book.load()?.items.count ?? 0
        let idx = TodayPick.index(for: Date(), count: count)
        let overridden = PickOverride.current(for: Date()) != nil
        let mode = Settings.load().mode
        print("""
        数据来源：\(source)
        选条方式：\(mode.title)\(overridden ? "（今天被「换一条」覆盖）" : "")
        今天：\(DailyPick.dayKey(for: Date()))  第 \(idx + 1) / \(count) 条

        \(item.t)
        【\(item.refText) · 第 \(item.c) 节「\(item.ct)」】
        成本：\(item.k)
        说人话：\(item.p)
        收益：\(item.g)
        证据等级：\(item.e)\(item.q.isEmpty ? "" : "（\(item.q)）")
        \(item.sourceText)
        """)
    }
}

// MARK: - 全文窗口

struct DetailView: View {
    var item: Item
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.ct.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)

                Text(item.t)
                    .font(.system(size: 21, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text("证据 \(item.e)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint(item.e))
                    if !item.q.isEmpty {
                        Text(item.q).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !item.m.isEmpty {
                        Text("·").foregroundStyle(.quaternary)
                        Text(item.m).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                Divider()

                field("说人话", item.p, primary: true)
                field("收益", item.g, primary: false)
                field("成本", item.k, primary: false)

                if !item.s.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("来源").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        ForEach(item.s, id: \.self) { host in
                            Text(host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                Text("《高性价比人生指南》\(item.refText) · CC BY 4.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 380, minHeight: 400)
    }

    private func tint(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B": return .orange
        default:  return .secondary
        }
    }

    private func field(_ name: String, _ text: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: primary ? 13 : 12))
                .foregroundStyle(primary ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 让系统重新取时间线

enum WidgetRefresher {
    /// 更新完缓存后请系统重新取时间线。不调的话要等系统自己的调度周期
    /// （可能几小时），用户会觉得「更新了但没变」。
    /// 这只是个建议，系统会按自己的预算安排。
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - 自己注册小组件

enum SelfRegister {
    /// 用 dmg 拖进来装的没有安装脚本，注册得靠 app 自己。
    ///
    /// 系统打开 app 时通常也会顺带登记里面的插件，但不保证立刻；
    /// 这里显式 pluginkit -a 一次，「编辑小组件」里马上就能搜到。
    /// 已经注册过再跑一遍是无害的，所以每次启动都做，不记状态。
    static func widget() {
        guard let plugins = Bundle.main.builtInPlugInsPath else { return }
        let appex = plugins + "/LifeWidgetExtension.appex"
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-a", appex]
            try? p.run()
            p.waitUntilExit()
        }
    }
}

// MARK: - 开机启动

enum LoginItem {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "loginItem")
    }

    /// 用 LaunchAgent plist，不碰 SMAppService ——
    /// 后者要求 app 有正确的签名和 bundle 结构，ad-hoc 签名的裸 app 会报错。
    static func toggle() {
        let enable = !isEnabled
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let path = dir + "/com.local.lifewidget.plist"

        if enable {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let exe = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.local.lifewidget</string>
                <key>ProgramArguments</key><array><string>\(exe)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><false/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: path, atomically: true, encoding: .utf8)
            run("/bin/launchctl", ["load", path])
        } else {
            run("/bin/launchctl", ["unload", path])
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.set(enable, forKey: "loginItem")
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - 入口

let app = NSApplication.shared
// AppDelegate 是 @MainActor 的；入口这段代码就跑在主线程上
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不进 Dock
app.run()
