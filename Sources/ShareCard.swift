import AppKit
import SwiftUI
import WidgetKit

// 「分享今天这条」的图片。
//
// 用的是小组件同一份视图（Widget/WidgetViews.swift 的 LifeWidgetView，大尺寸），
// 所以分享出去的跟桌面上看到的一样；只是去掉了右上角的按钮，底下加一行出处 ——
// 书是 CC BY 4.0，转出去的图必须带署名。

enum ShareCard {
    /// 画成图片。跟随系统的浅色 / 深色。
    @MainActor
    static func image(for item: Item, dark: Bool) -> NSImage? {
        let r = ImageRenderer(content: ShareCardView(item: item)
            .environment(\.colorScheme, dark ? .dark : .light))
        r.scale = 2   // 发到手机上也清楚
        return r.nsImage
    }

    @MainActor
    static func png(for item: Item, dark: Bool) -> Data? {
        guard let tiff = image(for: item, dark: dark)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// 写到临时目录，给分享面板用（文件比 NSImage 兼容的 app 多，比如微信、邮件）。
    /// 文件名带上条目标题，对方收到时一眼知道是什么。
    @MainActor
    static func file(for item: Item, dark: Bool) -> URL? {
        guard let data = png(for: item, dark: dark) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LifeWidget-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(item.t.prefix(24)).replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("今日一条 · \(safe).png")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

struct ShareCardView: View {
    @Environment(\.colorScheme) private var scheme
    var item: Item

    var body: some View {
        VStack(spacing: 14) {
            LifeWidgetView(
                entry: DailyEntry(date: Date(), item: item, isToday: true),
                familyOverride: .systemLarge,
                showsControls: false)
                // 系统给小组件的默认内边距，离屏渲染时没有，手动补上
                .padding(16)
                .frame(width: 364, height: 382)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(scheme == .dark ? Color(white: 0.17) : Color.white))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 12, y: 5)

            VStack(spacing: 3) {
                Text("《高性价比人生指南》\(item.refText) · CC BY 4.0")
                Text(footnote)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45))
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.20, green: 0.14, blue: 0.24)]
                    : [Color(red: 0.80, green: 0.87, blue: 0.95), Color(red: 0.95, green: 0.88, blue: 0.84)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var footnote: String {
        AppUpdater.repo.isEmpty ? "来自「今日一条」macOS 桌面小组件" : "来自「今日一条」macOS 桌面小组件 · github.com/\(AppUpdater.repo)"
    }
}
