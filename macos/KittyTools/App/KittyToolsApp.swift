// 应用入口：@main + 菜单栏菜单（唯一的 scene）。LSUIElement 应用，不显示 Dock 图标。
// 菜单项随里程碑补全（PLAN §4）。热键菜单项显示当前生效的组合，没设置时标「未设置」；有钉图时可隐藏 / 关闭全部。

import SwiftUI

@main
struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @AppStorage(Prefs.translateCopyToTranslate) private var copyToTranslate = false

  var body: some Scene {
    MenuBarExtra("Kitty Tools Native", systemImage: "cat") {
      hotKeyButton("启动器", .launcher) { appDelegate.toggleLauncher() }
      hotKeyButton("剪贴板历史", .clipboard) { appDelegate.toggleClipboard() }
      hotKeyButton("划词翻译", .selectionTranslate) { appDelegate.selectionTranslate() }
      hotKeyButton("截图翻译", .screenshotTranslate) { appDelegate.screenshotTranslate() }
      hotKeyButton("输入翻译", .inputTranslate) { appDelegate.showInputTranslate() }
      Toggle("复制即译", isOn: $copyToTranslate)
      Divider()
      hotKeyButton("截图", .screenshot) { appDelegate.screenshot() }
      hotKeyButton("截取上次区域", .screenshotLastRegion) {
        appDelegate.screenshot(repeatingLastRegion: true)
      }
      if !appDelegate.pins.panels.isEmpty {
        Button(appDelegate.pins.isHidden ? "显示全部钉图" : "隐藏全部钉图") {
          appDelegate.pins.toggleHidden()
        }
        Button("关闭全部钉图") { appDelegate.pins.closeAll() }
      }
      Divider()
      Button("设置…") { appDelegate.showSettings() }
        .keyboardShortcut(",")
      Button("关于 Kitty Tools Native") { appDelegate.showSettings(tab: "关于") }
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
