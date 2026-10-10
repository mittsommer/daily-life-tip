import SwiftUI
import AppKit

// 手机版（iPhone）界面预览。
//
// 为什么是「预览」而不是真的 iOS app：iOS 的 SDK、模拟器、真机安装都只随 Xcode 提供，
// 而这台机器只有 Command Line Tools。所以这里做的是 —— 手机版的界面和逻辑按手机尺寸
// 写出来，用 macOS 编译成一个窗口大小等于 iPhone 屏幕的 app，在本机跑起来看效果。
//
// 好处是选条方式、书稿数据、存储、分享图这些跨平台的代码（Sources/Shared.swift、
// Widget/WidgetViews.swift、Sources/ShareCard.swift）是**同一份**，将来真的做 iOS 版时
// 这部分不用重写，只需要补 Xcode 工程、iOS 小组件 extension 和签名。
//
// 两种跑法：
//   ./ios-preview.sh            打开窗口，可以点、可以滚
//   ./ios-preview.sh --render   把四个页面各渲染成一张 PNG（写视觉稿用，不用截屏）

@main
struct PhonePreviewApp: App {
    init() {
        // --render <目录>：渲染完就退出，不开窗口
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render") {
            let dir = args.count > i + 1 && !args[i + 1].hasPrefix("-") ? args[i + 1] : "build/phone"
            PhoneRender.run(into: dir)
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("iPhone 预览 · 今日一条") {
            PhoneFrame { PhoneRoot() }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: PhoneMetrics.outer.width, height: PhoneMetrics.outer.height)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// 把四个页面分别画成 PNG。跟 README 的截图同一个思路：离屏渲染，不用截屏，
/// 也就不会把桌面上的别的东西拍进去。
enum PhoneRender {
    @MainActor
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for tab in PhoneTab.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let view = PhoneFrame { PhoneRoot(initialTab: tab) }
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("❌ \(tab.title) 渲染失败"); continue
                }
                let name = "\(tab.key)-\(scheme == .light ? "light" : "dark").png"
                let path = "\(dir)/\(name)"
                do { try png.write(to: URL(fileURLWithPath: path)) }
                catch { print("❌ \(path)：\(error.localizedDescription)"); continue }
                print("✅ \(path)")
            }
        }
    }
}

/// iPhone 15 / 16 那一档的逻辑分辨率和安全区
enum PhoneMetrics {
    static let screen = CGSize(width: 393, height: 852)
    /// 状态栏 + 灵动岛
    static let safeTop: CGFloat = 54
    /// Home 条
    static let safeBottom: CGFloat = 26
    static let bezel: CGFloat = 13
    static var outer: CGSize { CGSize(width: screen.width + bezel * 2, height: screen.height + bezel * 2) }
}

/// 手机外框：黑色边框 + 圆角 + 灵动岛，里面装屏幕内容。
struct PhoneFrame<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var content: () -> Content

    var body: some View {
        content()
            .frame(width: PhoneMetrics.screen.width, height: PhoneMetrics.screen.height)
            .background(scheme == .dark ? Color.black : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 52, style: .continuous))
            .overlay(alignment: .top) {
                // 灵动岛
                Capsule().fill(.black)
                    .frame(width: 118, height: 33)
                    .padding(.top, 11)
            }
            .padding(PhoneMetrics.bezel)
            .background(
                RoundedRectangle(cornerRadius: 52 + PhoneMetrics.bezel, style: .continuous)
                    .fill(Color(white: scheme == .dark ? 0.22 : 0.13)))
    }
}
