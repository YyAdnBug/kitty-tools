// 应用入口：@main + 菜单栏菜单（唯一的 scene）。LSUIElement 应用，不显示 Dock 图标。
// 菜单项随里程碑补全（PLAN §4）。热键菜单项显示当前生效的组合，没设置时标「未设置」。

import SwiftUI

@main
struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false

  var body: some Scene {
    MenuBarExtra("Kitty Tools Native", systemImage: "cat") {
      hotKeyButton("剪贴板历史", .clipboard) { appDelegate.toggleClipboard() }
      hotKeyButton("划词翻译", .selectionTranslate) { appDelegate.selectionTranslate() }
      hotKeyButton("输入翻译", .inputTranslate) { appDelegate.showInputTranslate() }
      Toggle("复制即译", isOn: $copyToTranslate)
      Divider()
      Button("设置…") { appDelegate.showSettings() }
        .keyboardShortcut(",")
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

  @ViewBuilder
  private func hotKeyButton(_ title: String, _ action: HotKeyAction, run: @escaping () -> Void)
    -> some View
  {
    if let hotKey = appDelegate.hotKeys.bindings[action], let key = hotKey.keyEquivalent {
      Button(title, action: run).keyboardShortcut(key, modifiers: hotKey.eventModifiers)
    } else {
      Button(appDelegate.hotKeys.bindings[action] == nil ? "\(title)（未设置快捷键）" : title, action: run)
    }
  }
}
