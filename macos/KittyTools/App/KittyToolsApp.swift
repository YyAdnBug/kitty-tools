// 应用入口：@main。菜单栏图标和菜单是 AppKit 的 NSStatusItem（StatusItem，AppDelegate 启动时建：D 阶段要给图标做动效，
// MenuBarExtra 拿不到它的 NSStatusItem）。这里保留一个不插入菜单栏的 MenuBarExtra 当唯一的 scene：
// 用 SwiftUI 的生命周期，设置窗打开时（.regular）才有系统的主菜单（编辑菜单里的拷贝粘贴等）。LSUIElement 应用，不显示 Dock 图标。

import SwiftUI

@main
struct KittyToolsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra("Kitty Tools Native", systemImage: "cat", isInserted: .constant(false)) {
      EmptyView()
    }
  }
}
