# 今日一条 · 高性价比人生指南

一个 macOS 桌面小组件：每天从《[高性价比人生指南](https://github.com/eternity4719/HowToLiveBetter)》里给你一条建议。

- 三种尺寸：小（只有标题）、中（标题 + 说人话）、大（成本 / 收益 / 证据等级 / 来源）
- 两种选条方式，在菜单栏切换：
  - **顺序一条**：从第 1 条开始，每天往后一条，把整本书读完
  - **随机一条**：每天随机一条，一周内不重复
- 小组件右上角的小圆圈：今天这条不想看，点一下换一条（只影响今天）
- 菜单栏常驻：看全文、复制、联网更新书稿、检查 app 新版本

需要 macOS 14（Sonoma）或更新版本，Apple 芯片和 Intel 都支持。

## 安装

1. 到 [Releases](../../releases/latest) 下载 `LifeWidget-x.y.z.dmg`
2. 打开后把 `LifeWidget` 拖进「应用程序」，再从「应用程序」里打开
3. 右键桌面 → 编辑小组件 → 搜「高性价比人生指南」→ 选尺寸拖出来

**第一次打开提示「无法验证开发者」**：这个 app 没有 Apple 开发者签名。在提示框点「完成」，然后打开「系统设置 → 隐私与安全性」，往下找到 LifeWidget，点「仍要打开」。

**升级**：菜单栏里点「检查新版本…」，会自动下载并替换。

## 从源码构建

只需要 Command Line Tools（`xcode-select --install`）和 Node.js，**不需要 Xcode**。

```bash
./build.sh      # 构建到 build/LifeWidget.app（第一次会自动拉取书稿）
./selftest.sh   # 小组件那一侧的离线自检
./install.sh    # 构建并装到 /Applications、注册小组件
```

发布新版本：

```bash
UPDATE_REPO=mittsommer/daily-life-tip VERSION=1.1.0 ./release.sh
```

### 不用 Xcode 构建 WidgetKit 小组件的几个坑

- appex 必须带 `com.apple.security.app-sandbox`，否则 `pkd` 直接拒收（"plug-ins must be sandboxed"），系统里搜不到小组件
- appex 的入口点必须是 `_NSExtensionMain`（`-Xlinker -e -Xlinker _NSExtensionMain`）
- 交互式按钮（AppIntent）需要 `Metadata.appintents`，这个通常由 Xcode 生成，这里用 `tools/embed-appintents.mjs` 手工生成。缺了它按钮能点、但什么都不发生
- 小组件的 `UserDefaults` 跟宿主 app 不通，共享状态要走文件

## 版权

书的内容来自 [eternity4719/HowToLiveBetter](https://github.com/eternity4719/HowToLiveBetter)，采用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 协议。本仓库不包含书稿本身，构建时从原仓库拉取。
