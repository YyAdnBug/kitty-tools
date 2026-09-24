// 设置窗：普通 NSWindow + NSTabViewController（工具栏样式标签），每个标签一个 NSHostingController，
// 窗口高度随标签内容自动变化。不用 SwiftUI Settings scene：LSUIElement 应用里它会被压到别的 App 后面，
// 浮层上的齿轮也调不到 openSettings。
// 打开：先收起浮层 → 切成 .regular（出现 Dock 图标）并激活；关闭时切回 .accessory。

import AppKit
import SwiftUI

final class SettingsWindow: NSObject, NSWindowDelegate {
  private let window: NSWindow

  init(tabs: [(title: String, symbol: String, view: AnyView)]) {
    let controller = NSTabViewController()
    controller.tabStyle = .toolbar
    for tab in tabs {
      let hosting = NSHostingController(rootView: tab.view)
      hosting.sizingOptions = .preferredContentSize
      let item = NSTabViewItem(viewController: hosting)
      item.label = tab.title
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
      controller.addTabViewItem(item)
    }
    window = NSWindow(contentViewController: controller)
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary]
    super.init()
    window.delegate = self
  }

  func show() {
    NSApp.setActivationPolicy(.regular)
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // macOS 14 起 activate() 是协作式的，前台 App 不让出时可能到不了最前：退回旧 API
    // （M3 验收实测三个入口，结论记进 mac-overlay-panel 技能）
    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
