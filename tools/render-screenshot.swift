// 把三种尺寸的小组件离屏渲染成 README 用的截图：docs/screenshot-{light,dark}.png
//
// 为什么不截真桌面：要把小组件摆好、挡住别的窗口、再裁剪，每次改界面都得手工重来，
// 还容易把桌面上别的东西拍进去。这里用的是小组件同一份视图代码，界面改了重跑一遍就行。
//
// 用法：./screenshot.sh

import SwiftUI
import WidgetKit

@main
struct RenderScreenshot {
    @MainActor
    static func main() {
        guard let payload = Book.load(preferCache: false), !payload.items.isEmpty else {
            print("❌ 书稿数据解不开"); exit(1)
        }
        let items = payload.items
        // 挑几条摆出来好看的：证据等级 A、标题不太长、有来源
        let medium = items[0]
        let small = items.first { $0.t.count <= 12 && $0.e == "A" && $0.i != medium.i } ?? items[1]
        let large = items.first {
            $0.e == "A" && $0.s.count >= 2 && $0.t.count <= 20 && !$0.m.isEmpty
                && $0.i != medium.i && $0.i != small.i
        } ?? items[2]

        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let view = Gallery(small: small, medium: medium, large: large)
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("❌ 渲染失败"); exit(1)
            }
            let name = scheme == .light ? "light" : "dark"
            let path = "\(out)/screenshot-\(name).png"
            do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("❌ \(error)"); exit(1) }
            print("✅ \(path)（\(Int(img.size.width * 2))×\(Int(img.size.height * 2))）")
        }
        print("   小：\(small.t)\n   中：\(medium.t)\n   大：\(large.t)")
    }
}

/// 三块小组件摆在一张「桌面」上：左边中 + 小，右边大
struct Gallery: View {
    @Environment(\.colorScheme) private var scheme
    var small: Item
    var medium: Item
    var large: Item

    // macOS 桌面小组件的尺寸（pt）
    static let smallSize = CGSize(width: 170, height: 170)
    static let mediumSize = CGSize(width: 364, height: 170)
    static let largeSize = CGSize(width: 364, height: 382)

    var body: some View {
        HStack(alignment: .top, spacing: 42) {
            VStack(alignment: .leading, spacing: 42) {
                card(medium, .systemMedium, Self.mediumSize)
                card(small, .systemSmall, Self.smallSize)
            }
            card(large, .systemLarge, Self.largeSize)
        }
        .padding(48)
        .background(wallpaper)
    }

    private func card(_ item: Item, _ family: WidgetFamily, _ size: CGSize) -> some View {
        LifeWidgetView(entry: DailyEntry(date: Date(), item: item, isToday: true), familyOverride: family)
            // 系统给小组件的默认内边距，离屏渲染时没有，手动补上
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.17).opacity(0.92) : Color.white.opacity(0.9))
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.14), radius: 14, y: 6)
    }

    private var wallpaper: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.20, green: 0.14, blue: 0.24)]
                : [Color(red: 0.80, green: 0.87, blue: 0.95), Color(red: 0.95, green: 0.88, blue: 0.84)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
