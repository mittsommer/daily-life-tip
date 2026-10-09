// 路径探针：沙盒进程到底能不能**写**到某个具体路径。
//
// 上一版探针（tools/sandbox-probe.swift）给过假阳性：它声称 App Group 读写成功，
// 其实组容器压根没被创建，它写的是 appSupportDir —— 而沙盒里 NSHomeDirectory()
// 指向自己的容器，于是「写进去再读回来」全在自己家里完成，必然成功。
//
// 这版的诚实之处：它打印**实际写入的绝对路径**，并且由驱动脚本从沙盒外
// 独立核对那个路径上真的出现了文件。沙盒内的读回一致不算证据。
//
// 用法：path-probe <目标目录> [<目标目录> ...]
// 每个目录写一个带随机标记的文件，打印结果。

import Foundation

@main
struct PathProbe {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("用法：path-probe <目录> [...]\n".utf8))
            exit(2)
        }

        let marker = ProcessInfo.processInfo.processIdentifier
        print("沙盒生效：\(NSHomeDirectory().contains("/Library/Containers/") ? "是" : "否")")
        print("NSHomeDirectory → \(NSHomeDirectory())")
        print("realHome        → \(SharedPaths.realHome)")
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedPaths.appGroup) {
            print("containerURL    → \(g.path)")
        } else {
            print("containerURL    → nil")
        }
        print()

        var anyFail = false
        for dir in args {
            // 文件名带上 pid，驱动脚本就知道该去哪个路径上找
            let name = "probe-\(marker).json"
            let path = dir + "/" + name
            let payload = Data("{\"pid\":\(marker)}".utf8)

            let mk = (try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)) != nil

            var writeErr: String? = nil
            do {
                try payload.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                writeErr = "\(error)"
            }

            let readBack = FileManager.default.contents(atPath: path)

            print("目标：\(path)")
            if let e = writeErr {
                print("  ❌ 写入失败：\(e)")
                print("     （mkdir 是否成功：\(mk ? "是" : "否")）")
                anyFail = true
            } else if readBack == nil {
                print("  ❌ 写入没报错，但读不回来 —— 可疑")
                anyFail = true
            } else {
                print("  ✅ 写入成功，读回一致（沙盒内自证，需外面核对）")
            }
            print()
        }

        // 打印出来给驱动脚本核对用
        print("PROBE_PID=\(marker)")
        exit(anyFail ? 1 : 0)
    }
}
