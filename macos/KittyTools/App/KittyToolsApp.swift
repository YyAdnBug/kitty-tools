// 应用入口：@main + 菜单栏菜单（唯一的 scene）。LSUIElement 应用，不显示 Dock 图标。
// M0 只有「关于」「退出」两项；其余菜单项随后续里程碑加入（PLAN §4）。

import SwiftUI

@main
struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("Kitty Tools Native", systemImage: "cat") {
      Button("关于 Kitty Tools Native") {
        // LSUIElement 应用不先激活，关于面板会被压在其它 App 后面
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
      }
      Divider()
      Button("退出") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .menuBarExtraStyle(.menu)
  }
}
