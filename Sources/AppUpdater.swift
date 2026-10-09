import Foundation

// 宿主 app 自己的版本更新。新版本以 dmg 的形式挂在 GitHub Releases 上。
//
// 跟 RemoteBook 是两回事：那个更新的是书的内容（数据），这个换的是 app 本身。
//
// 流程：查 releases/latest → 下载 dmg → 挂载 → 核对 → 拷到 app 旁边暂存 →
// 起一个小脚本，等本进程退出后把暂存的那份换上去、重新打开。
// 换文件必须等进程退出：正在跑的 app 把自己删掉换新，菜单栏里留下的还是旧进程。

enum AppUpdater {
    struct Release {
        var version: String
        var notes: String
        var dmgURL: URL
        var pageURL: URL?
    }

    enum CheckResult {
        case available(Release)
        case upToDate(latest: String)
        case notConfigured
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// owner/repo。构建时由 build.sh 的 UPDATE_REPO 写进 Info.plist，空的就是没配。
    static var repo: String {
        (Bundle.main.object(forInfoDictionaryKey: "LWUpdateRepo") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 查最新版本的地址。LIFEWIDGET_UPDATE_API 只给测试用：指到本地假服务器，
    /// 不然要验证更新流程就得真去 GitHub 发一个版本。
    static var latestURL: URL? {
        if let s = ProcessInfo.processInfo.environment["LIFEWIDGET_UPDATE_API"], !s.isEmpty {
            return URL(string: s)
        }
        guard !repo.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    // MARK: 检查

    /// GitHub releases/latest 的返回，只取用得到的字段。
    /// releases/latest 本身就跳过了草稿和预发布版。
    private struct GHRelease: Decodable {
        var tagName: String
        var body: String?
        var htmlUrl: String?
        var assets: [Asset]
        struct Asset: Decodable {
            var name: String
            var browserDownloadUrl: String
        }
    }

    static func check() -> CheckResult {
        guard let url = latestURL else { return .notConfigured }
        let data: Data
        do {
            data = try fetch(url)
        } catch let e as UpdateError where e.errorDescription == "HTTP 404" {
            return .failed("仓库里还没有发布过版本")
        } catch {
            // API 不通就走网页跳转。最常见的原因是限额：未登录的 API 每个 IP 每小时 60 次，
            // 公司网络、VPN 出口是很多人共用一个 IP，经常早就被别人用光了（实测踩到过）。
            return checkViaRedirect() ?? .failed(error.localizedDescription)
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let gh = try? dec.decode(GHRelease.self, from: data) else {
            return .failed("发布信息看不懂")
        }
        let version = gh.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard isNewer(version, than: currentVersion) else { return .upToDate(latest: version) }
        guard let asset = gh.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmg = URL(string: asset.browserDownloadUrl) else {
            return .failed("新版本 \(version) 的发布里没有 dmg 文件")
        }
        return .available(Release(
            version: version,
            notes: gh.body ?? "",
            dmgURL: dmg,
            pageURL: gh.htmlUrl.flatMap(URL.init(string:))))
    }

    /// 不走 API 的退路：github.com/<repo>/releases/latest 这个网页会 302 到
    /// /releases/tag/v1.2.3，跳转后的地址里就有版本号。网页不受 API 限额约束。
    ///
    /// 拿不到更新说明（那个只有 API 给），dmg 地址按 package.sh 的命名规则拼：
    /// LifeWidget-<版本>.dmg —— 改了那边的文件名，这里要跟着改。
    /// 没配仓库时返回 nil。测这条路：配好仓库、把 LIFEWIDGET_UPDATE_API 指到连不上的地址。
    private static func checkViaRedirect() -> CheckResult? {
        guard !repo.isEmpty,
              let page = URL(string: "https://github.com/\(repo)/releases/latest") else { return nil }

        let sem = DispatchSemaphore(value: 0)
        var finalURL: URL?
        var req = URLRequest(url: page)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            defer { sem.signal() }
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { finalURL = http.url }
        }.resume()
        guard sem.wait(timeout: .now() + 20) == .success, let finalURL else { return nil }

        // 没发布过版本时会跳到 /releases 而不是 /releases/tag/…
        let parts = finalURL.pathComponents
        guard let i = parts.firstIndex(of: "tag"), i + 1 < parts.count else {
            return .failed("仓库里还没有发布过版本")
        }
        let tag = parts[i + 1]
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard isNewer(version, than: currentVersion) else { return .upToDate(latest: version) }
        guard let dmg = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/LifeWidget-\(version).dmg") else {
            return nil
        }
        return .available(Release(version: version, notes: "", dmgURL: dmg, pageURL: finalURL))
    }

    /// 按点分段逐段比数字：1.10.0 比 1.9.0 新（按字符串比就错了）。
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: 安装

    /// 下载、核对、暂存，然后交给替换脚本。成功返回后调用方应**立刻退出进程**，
    /// 脚本等到进程退出才动手。任何一步失败都抛出，原来的 app 不受影响。
    static func install(_ r: Release, relaunch: Bool = true) throws {
        let dest = Bundle.main.bundlePath
        let fm = FileManager.default

        // 在安装盘里跑的那份不能换：一弹出就没了
        guard !dest.hasPrefix("/Volumes/") else {
            throw UpdateError("请先把 app 拖进「应用程序」再更新")
        }
        let parent = (dest as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else {
            throw UpdateError("没有权限写入 \(parent)")
        }
        // 以前用 .pkg 装过的那份归 root，删不掉（踩过：访达报「必须跳过某些项目」）
        if let owner = try? fm.attributesOfItem(atPath: dest)[.ownerAccountName] as? String,
           owner != NSUserName() {
            throw UpdateError("\(dest) 归 \(owner) 所有，没法替换。请手动下载新版，把旧版拖进废纸篓后再装")
        }

        let work = NSTemporaryDirectory() + "lifewidget-update-" + UUID().uuidString
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: work) }

        let dmg = work + "/update.dmg"
        try download(r.dmgURL, to: dmg)

        let mnt = work + "/mnt"
        try run("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mnt, "-force", "-quiet"]) }

        guard let name = try fm.contentsOfDirectory(atPath: mnt).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("dmg 里没有 app")
        }
        let newApp = mnt + "/" + name

        // 核对：同一个 app、签名完好、版本确实比现在的新。
        // ad-hoc 签名没有开发者身份可比，能防的是「下错了包」和「下载损坏」，
        // 防不了有人顶替发布 —— 那个只有正式的开发者签名能防。
        let info = NSDictionary(contentsOfFile: newApp + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("dmg 里的不是这个 app")
        }
        let newVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(newVersion, than: currentVersion) else {
            throw UpdateError("dmg 里的版本是 \(newVersion)，不比当前的 \(currentVersion) 新")
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp])
        } catch {
            throw UpdateError("新版本签名校验没过，没有安装")
        }

        // 暂存在 app 旁边：同一个卷上，替换时 mv 是原子的，不会出现装了一半
        let staged = dest + ".updating"
        try? fm.removeItem(atPath: staged)
        try run("/usr/bin/ditto", [newApp, staged])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged])

        // 替换脚本。先把旧的挪成 .old，新的挪进来，成功再删 .old；
        // 挪新的失败就把旧的挪回去 —— 最坏情况也是留着旧版，不会一个都没有。
        let script = """
        PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
        for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        OLD="$DEST.old"
        rm -rf "$OLD"
        if mv "$DEST" "$OLD"; then
          if mv "$NEW" "$DEST"; then rm -rf "$OLD"; else mv "$OLD" "$DEST"; rm -rf "$NEW"; fi
        fi
        [ "$RELAUNCH" = 1 ] && /usr/bin/open "$DEST"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "lifewidget-update",
                       String(ProcessInfo.processInfo.processIdentifier), staged, dest, relaunch ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: 工具

    private static func fetch(_ url: URL, timeout: TimeInterval = 15) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(err); return }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(UpdateError("HTTP \(http.statusCode)")); return
            }
            result = .success(data ?? Data())
        }.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut { throw UpdateError("连接超时") }
        return try result.get()
    }

    private static func download(_ url: URL, to path: String) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            defer { sem.signal() }
            if let err { failure = err; return }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = UpdateError("下载失败：HTTP \(http.statusCode)"); return
            }
            // 临时文件在这个回调返回后就被删，必须在这里挪走
            guard let tmp else { failure = UpdateError("下载失败"); return }
            do { try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: path)) }
            catch { failure = error }
        }.resume()
        if sem.wait(timeout: .now() + 300) == .timedOut { throw UpdateError("下载超时") }
        if let failure { throw failure }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) 失败：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
