// 自家写剪贴板与模拟粘贴的唯一出口（mac-native §5）。写入后记下 changeCount 让 watcher 跳过，
// 并加 nspasteboard.org 的 TransientType：共存的 Tauri 版和别的剪贴板工具也不会把它记进历史。

import AppKit
import Carbon.HIToolbox

enum Paster {
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  /// 自家最近一次写入后的 changeCount
  private(set) static var ownChangeCount = -1

  /// 一个 item 的多种表示一次写完（分两次 declare 会互相清空）
  static func write(_ representations: [NSPasteboard.PasteboardType: Data]) {
    let item = NSPasteboardItem()
    for (type, data) in representations { item.setData(data, forType: type) }
    item.setData(Data(), forType: transientType)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
    ownChangeCount = pasteboard.changeCount
  }

  static func write(string: String) {
    write([.string: Data(string.utf8)])
  }

  /// 向前台 App 发 ⌘V。浮层不激活本 App，前台一直是原 App，所以不用等待、不用切前台。
  /// 未授权返回 false，内容仍留在剪贴板里
  static func pasteToFrontmost() -> Bool {
    guard Permissions.isAccessibilityTrusted else { return false }
    // ponytail: 按物理键位发 V（kVK_ANSI_V），Dvorak 这类布局下会变成别的键；真有人用再按布局查键码
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
      // 显式设 flags：热键里还按着的 ⇧ 不会混进来变成 ⌘⇧V
      event?.flags = .maskCommand
      event?.post(tap: .cgSessionEventTap)
    }
    return true
  }
}
