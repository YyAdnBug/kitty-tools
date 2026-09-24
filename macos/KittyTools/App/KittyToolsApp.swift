// 应用入口：@main + 菜单栏菜单（唯一的 scene）。LSUIElement 应用，不显示 Dock 图标。
// 菜单项随里程碑补全（PLAN §4）：M1 有剪贴板历史、输入翻译、关于、退出。

import SwiftUI

@main
struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("Kitty Tools Native", systemImage: "cat") {
      Button("剪贴板历史") { appDelegate.toggleClipboard() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
      Button("输入翻译") { appDelegate.showInputTranslate() }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      Divider()
      Button("关于 Kitty Tools Native") {
        // LSUIElement 应用不先激活，关于面板会被压在其它 App 后面
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
      }
      Button("退出") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .menuBarExtraStyle(.menu)
  }
}
