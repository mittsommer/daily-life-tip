import Foundation
import os

// 可选的联网更新：从 GitHub 拉最新书稿，解析成条目，写进共享缓存。
//
// 内置的那份数据是编译时快照，永远能出内容。这里只负责「书更新了，跟上去」。
// 拉取失败、解析异常、条目数对不上，一律安静地放弃，保留内置数据 ——
// 宁可显示编译时的那条，也不要写一份半截的书进缓存。

enum RemoteBook {
    static let commitAPI = URL(string: "https://api.github.com/repos/eternity4719/HowToLiveBetter/commits/main")!
    static let rawBase = "https://raw.githubusercontent.com/eternity4719/HowToLiveBetter/main/book/"

    /// 全书条目数。写缓存前拿它校验 —— 书里少解析出一个字段或多出一个新字段，
    /// 都会让这个数对不上，那就别覆盖用户手上那份好的。
    static let expectedCount = 672

    static let log = Logger(subsystem: "com.local.lifewidget", category: "remote")

    private static func fetch(_ url: URL, timeout: TimeInterval = 15) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("LifeWidget/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .failure(err); return }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(URLError(.badServerResponse)); return
            }
            result = .success(data ?? Data())
        }.resume()
        // 同步等 —— 调用方已经在后台队列上了
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            throw URLError(.timedOut)
        }
        return try result.get()
    }

    /// 名字形如 01-不要早死.md，用来排序和取节号
    private static func chapterNumber(_ file: String) -> (Int, String)? {
        let stem = file.replacingOccurrences(of: ".md", with: "")
        let parts = stem.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let num = Int(parts[0]) else { return nil }
        return (num, String(parts[1]))
    }

    /// 解析单章。规则跟 tools/embed.mjs 保持一致，改了那边记得同步这里。
    private static func parseChapter(_ text: String, num: Int, title: String, startID: Int) -> [Item] {
        var items: [Item] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n### ")
            .dropFirst()   // 第一块是节首导语

        for block in blocks {
            var lines = block.components(separatedBy: "\n")
            guard !lines.isEmpty else { continue }
            let head = lines.removeFirst().trimmingCharacters(in: .whitespaces)

            // 标题行：### 1. 系安全带，前排后排都系
            guard let dot = head.firstIndex(of: "."),
                  let no = Int(head[head.startIndex..<dot].trimmingCharacters(in: .whitespaces))
            else { continue }
            let itemTitle = String(head[head.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            guard !itemTitle.isEmpty else { continue }

            let body = lines.joined(separator: "\n")
            var fields: [String: String] = [:]
            var order: [String] = []

            for line in body.components(separatedBy: "\n") {
                if line.hasPrefix("- "), let colon = line.firstIndex(of: "：") {
                    let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon])
                    let value = String(line[line.index(after: colon)...])
                    if ["备注", "成本", "来源", "收益", "说人话", "证据等级"].contains(name) {
                        fields[name] = value
                        order.append(name)
                        continue
                    }
                }
                // 续行接到上一个字段
                if let last = order.last, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    fields[last] = (fields[last] ?? "") + "\n" + line.trimmingCharacters(in: .whitespaces)
                }
            }

            let evidence = (fields["证据等级"] ?? "").trimmingCharacters(in: .whitespaces)
            let (grade, qualifier) = splitEvidence(evidence)

            let tags = parseTags(body)
            let item = Item(
                i: startID + items.count,
                c: num, ct: title, n: no,
                t: itemTitle,
                k: fields["成本"] ?? "",
                p: fields["说人话"] ?? "",
                g: brief(fields["收益"] ?? ""),
                e: grade,
                q: shorten(qualifier),
                s: sourceHosts(fields["来源"] ?? ""),
                m: [
                    tags["钱"].map { "钱\($0)" },
                    tags["时间"].map { "时\($0)" },
                    tags["毅力"] == "是" ? "要毅力" : nil,
                    tags["收益"].map { "收益\($0)" },
                ].compactMap { $0 }.joined(separator: " · "))
            items.append(item)
        }
        return items
    }

    private static func parseTags(_ body: String) -> [String: String] {
        guard let r = body.range(of: "成本标签") else { return [:] }
        let tail = body[r.upperBound...]
        guard let end = tail.range(of: "-->") else { return [:] }
        var out: [String: String] = [:]
        for part in tail[..<end.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0]).trimmingCharacters(in: CharacterSet(charactersIn: "：: "))] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    private static func splitEvidence(_ raw: String) -> (String, String) {
        guard let first = raw.first else { return ("", "") }
        var rest = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "（）()"))
        return (String(first), rest)
    }

    private static func shorten(_ q: String) -> String {
        if q.isEmpty { return "" }
        if q.contains("争议") { return "有争议" }
        if q.contains("指南") { return "指南强推" }
        return q.count > 6 ? String(q.prefix(6)) + "…" : q
    }

    private static func brief(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let limit = 120
        guard t.count > limit else { return t }
        let cut = String(t.prefix(limit))
        let stop = max(cut.lastIndex(of: "。")?.utf16Offset(in: cut) ?? -1,
                       cut.lastIndex(of: "；")?.utf16Offset(in: cut) ?? -1)
        return stop > limit / 2 ? String(cut.prefix(stop + 1)) : cut + "…"
    }

    /// 来源里一串 <https://…>，只留域名 —— 小组件放不下完整 URL。
    ///
    /// 注意别写成「找 < 再找下一个 >」：正文里会有 `<70 mg/dL (<3.9 mmol/L) and ≥54 mg/dL`
    /// 这种裸尖括号，而且**它们自己还嵌套**（第 13 节第 17 条就是这样）。
    /// 所以匹配失败时只能往前挪一个字符，不能跳到 `>` 之后 —— 那样会把夹在中间的
    /// 真正的链接一起跳过。跟 tools/embed.mjs 的正则要求一致：`<` 后面必须紧跟 http。
    private static func sourceHosts(_ text: String) -> [String] {
        var hosts: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: ">") else { break }
            let inner = rest[after..<close]
            guard inner.hasPrefix("http://") || inner.hasPrefix("https://"),
                  let url = URL(string: String(inner)), let host = url.host
            else {
                rest = rest[after...]   // 只挪一个字符，别跳过嵌套的 <
                continue
            }
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !hosts.contains(h) { hosts.append(h) }
            rest = rest[rest.index(after: close)...]
        }
        return hosts
    }

    // MARK: 出口

    /// 离线自检：用这里这套解析器（联网更新走的那条路）读本地 book/ 目录，
    /// 和编译进来的那 672 条逐条比对。
    ///
    /// 存在的理由：解析逻辑有两份实现 —— tools/embed.mjs（构建时）和这里（运行时）。
    /// 两份跑偏了不会报错，只会让「联网更新」悄悄换成一份不同的书。
    /// 改任何一份之后跑 `LifeWidget --selftest <book目录>` 对一遍。
    static func selfTest(bookDir: String) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: bookDir) else {
            print("❌ 读不到目录 \(bookDir)"); return false
        }

        let chapters = files.compactMap { name -> (Int, String, String)? in
            guard name.hasSuffix(".md"), let (num, title) = chapterNumber(name) else { return nil }
            return (num, title, name)
        }.sorted { $0.0 < $1.0 }

        var parsed: [Item] = []
        for (num, title, file) in chapters {
            let path = bookDir + "/" + file
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            parsed.append(contentsOf: parseChapter(text, num: num, title: title, startID: parsed.count))
        }

        guard let bundled = Book.load(preferCache: false)?.items else {
            print("❌ 内置数据读不出来"); return false
        }

        var ok = true
        if parsed.count != bundled.count {
            print("❌ 条数不一致：Swift 解析 \(parsed.count)，内置 \(bundled.count)")
            ok = false
        }
        // 逐条比对标题 —— 标题错位说明某一条被漏掉或多解析了
        for (a, b) in zip(parsed, bundled) where a.t != b.t || a.c != b.c || a.n != b.n {
            print("❌ 第 \(a.c) 节第 \(a.n) 条不一致：\n   Swift: \(a.t)\n   内置:  \(b.t)")
            ok = false
            break
        }
        // 字段抽查：证据等级和来源域名分布应当完全一致
        let ae = parsed.map(\.e).sorted(), be = bundled.map(\.e).sorted()
        if ae != be { print("❌ 证据等级分布不一致"); ok = false }
        let asrc = parsed.map { $0.s.joined(separator: ",") }
        let bsrc = bundled.map { $0.s.joined(separator: ",") }
        if asrc.sorted() != bsrc.sorted() {
            print("❌ 来源域名分布不一致")
            // 按下标找第一处，而不是按排序后比 —— 排序比对只能说明「有多处」，
            // 定位不到是哪一条
            for idx in 0..<min(asrc.count, bsrc.count) where asrc[idx] != bsrc[idx] {
                let a = parsed[idx]
                print("   下标 \(idx) → 第 \(a.c) 节第 \(a.n) 条「\(a.t.prefix(24))」")
                print("     Swift: [\(asrc[idx])]")
                print("     内置:  [\(bsrc[idx])]")
                break
            }
            ok = false
        }

        print(ok
              ? "✅ 两套解析器一致：\(parsed.count) 条，标题/节号/证据等级/来源全部对得上"
              : "⚠️  两套解析器有分歧，上面是第一个不一致的地方")
        return ok
    }

    enum UpdateResult {
        case updated(commit: String, count: Int)
        case unchanged
        case failed(String)
    }

    /// 拉最新书稿。在后台队列上调用，会阻塞到网络返回。
    static func updateIfNeeded(force: Bool = false) -> UpdateResult {
        do {
            let head = try fetch(commitAPI)
            guard let obj = try JSONSerialization.jsonObject(with: head) as? [String: Any],
                  let sha = obj["sha"] as? String else {
                return .failed("拿不到最新提交号")
            }

            // 已经是最新的就不重复下载 34 个文件
            if !force, ItemsCache.read() != nil {
                let stamp = UserDefaults.standard.string(forKey: "lastCommit")
                if stamp == sha { return .unchanged }
            }

            // 先列目录。用 git tree API，省得把文件名写死在代码里。
            let treeURL = URL(string: "https://api.github.com/repos/eternity4719/HowToLiveBetter/contents/book?ref=main")!
            let listing = try fetch(treeURL)
            guard let entries = try JSONSerialization.jsonObject(with: listing) as? [[String: Any]] else {
                return .failed("目录列表读不出来")
            }
            let names = entries.compactMap { $0["name"] as? String }.filter { $0.hasSuffix(".md") }
            guard names.count >= 30 else { return .failed("章节数不对（\(names.count) 个）") }

            let chapters = names.compactMap { name -> (Int, String, String)? in
                guard let (num, title) = chapterNumber(name) else { return nil }
                return (num, title, name)
            }.sorted { $0.0 < $1.0 }

            var items: [Item] = []
            var chaptersMeta: [BookPayload.Chapter] = []
            for (num, title, file) in chapters {
                let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
                guard let url = URL(string: rawBase + encoded) else { continue }
                let text = String(data: try fetch(url, timeout: 20), encoding: .utf8) ?? ""
                let parsed = parseChapter(text, num: num, title: title, startID: items.count)
                chaptersMeta.append(.init(num: num, title: title, count: parsed.count))
                items.append(contentsOf: parsed)
            }

            // 校验。对不上就不覆盖 —— 多半是书的正文格式变了，这里的解析器该跟着改。
            guard items.count == expectedCount else {
                log.error("条目数 \(items.count) ≠ \(expectedCount)，保留内置数据")
                return .failed("解析出 \(items.count) 条，预期 \(expectedCount) 条，已保留原数据")
            }

            let payload = BookPayload(
                title: BookData.bookTitle, repo: "https://github.com/eternity4719/HowToLiveBetter",
                license: "CC BY 4.0", count: items.count,
                chapters: chaptersMeta, items: items)
            ItemsCache.write(ItemsCache(payload: payload, fetchedAt: Date()))
            UserDefaults.standard.set(sha, forKey: "lastCommit")
            log.info("更新成功，\(items.count) 条 @ \(sha.prefix(7))")
            return .updated(commit: String(sha.prefix(7)), count: items.count)
        } catch {
            log.error("更新失败：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
