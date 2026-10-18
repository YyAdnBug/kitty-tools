// 从不激活本 App 的地方开系统的存储 / 打开面板（截图「另存为」、翻译历史导出、便签的「插入图片…」和单条导出）的唯一入口。
// 这些地方本 App 不在前台（浮层、便签那叠、浮动便签都是不激活的面板）。原来的写法是先 NSApp.activate()、
// 不行再 activate(ignoringOtherApps:)，然后 begin——2026-10-18 在 macOS 27 上实测（macos/build/research/panel-repro/）：
// 两个都被系统驳回，面板照样 begin 了，却开在前台 App 的窗口**后面**，用户看着就是「点了没反应」（用户真机报：便签单条导出、
// 右键「插入图片…」）。所以：照旧请求激活，再把面板提到 .modalPanel 这一层、orderFrontRegardless——没激活成也一定在最上面
// 看得见，点它一下本 App 就到前台、键盘也到它那里。关掉之后把前台还给原来的 App。
// 「本 App 在不在前台」看 frontmostApplication，不看 NSApp.isActive：同一次实测里刚切走时 isActive 还是 true（过期），
// 原来的判断因此连激活都没试。

import AppKit

enum FilePanel {
  /// 开一个存储 / 打开面板（NSOpenPanel 是 NSSavePanel 的子类），关掉后调 completion（前台已经还回去了）
  static func begin(
    _ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    let me = NSRunningApplication.current.processIdentifier
    let front = NSWorkspace.shared.frontmostApplication
    let previous = front?.processIdentifier == me ? nil : front
    if previous != nil {
      NSApp.activate()
      if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
    panel.begin { response in
      previous?.activate()
      completion(response)
    }
    // begin 之后再提层级、拿到最前（begin 之前设的层级会被它改回去）
    panel.level = .modalPanel
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  /// 同上，等它关掉（async 的调用方用）
  static func begin(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
    await withCheckedContinuation { continuation in
      begin(panel) { continuation.resume(returning: $0) }
    }
  }
}
