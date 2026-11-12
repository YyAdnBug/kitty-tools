// 应用入口：@main。菜单栏图标和菜单是 AppKit 的 NSStatusItem（StatusItem，AppDelegate 启动时建：D 阶段要给图标做动效，
// MenuBarExtra 拿不到它的 NSStatusItem）。这里保留一个不插入菜单栏的 MenuBarExtra 当唯一的 scene：
// 用 SwiftUI 的生命周期，采用普通应用策略（.regular）时显示系统主菜单（编辑菜单里的拷贝粘贴等；显示菜单里加了设置窗的
// 「返回 ⌘[」；App 菜单的「关于 Kitty Tools」换成自己的品牌关于页，和菜单栏的「关于」是同一个；没有帮助文档，去掉帮助项）。
// macOS 26 默认在 SwiftUI 启动前设为 .regular、程序坞图标常驻（避免运行中切换策略后浮层丢键盘；设置 › 通用能关）。
// 其他系统仍按 LSUIElement 启动，只在普通窗口打开时显示 Dock 图标。
// 真正的入口是 Main：带 --ocr 起的是剪贴板后台识字的子进程（OCR.recognizeTextInHelper），只识字、写标准输出、退出，
// 不启动 SwiftUI / NSApplication（没有菜单栏图标、热键，不碰偏好 / 数据库 / 钥匙串，也不走单实例检查）。
// 它只肯识本 App 数据目录的 images 和临时目录里的图（OCR.helperRoots：参数是信任边界）。

import AppKit
import SwiftUI

@main
enum Main {
  static func main() {
    switch OCR.launch(CommandLine.arguments) {
    case .recognize(let image):
      // 识字是异步的：主线程交给 dispatchMain 转着，识完直接 exit
      Task { exit(await OCR.runHelper(image)) }
      dispatchMain()
    case .usage:
      FileHandle.standardError.write(Data("用法：\(OCR.helperFlag) <图片路径>\n".utf8))
      exit(2)
    case nil:
      // 本进程的环境会经 NSWorkspace 原样传给从这里打开的 App（启动器、启动台、访达右键「用 App 打开」……，
      // 2026-11-12 实测 PATH、SHLVL 都照传）。应用内更新经 /bin/sh 调 open 重启本 App，sh 加上的 SHLVL=1、PWD、_
      // 就跟着到了被打开的 App：JetBrains 的 IDE 见 SHLVL > 0 当成从终端起的，不读登录 shell 的环境（PATH 里
      // 没有 /opt/homebrew/bin）。启动时去掉 shell 留下的这几个，打开的 App 和从访达打开的一样
      for key in ["SHLVL", "PWD", "OLDPWD", "_"] { unsetenv(key) }
      // macOS 26 默认程序坞图标常驻：进 SwiftUI 之前就设成 .regular（见 NSApplication.keepsDockIcon）
      if NSApplication.keepsDockIcon { NSApplication.shared.setActivationPolicy(.regular) }
      KittyToolsApp.main()
    }
  }
}

struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("Kitty Tools", image: "StatusIcon", isInserted: .constant(false)) {
      EmptyView()
    }
    .commands {
      SettingsCommands(navigation: appDelegate.settingsNavigation)
      CommandGroup(replacing: .appInfo) {
        Button("关于 Kitty Tools") { appDelegate.showSettings(page: .about) }
      }
      CommandGroup(replacing: .help) {}
    }
  }
}
