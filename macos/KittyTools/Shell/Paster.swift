// 自家写剪贴板与模拟粘贴的唯一出口（mac-native §5）。写入后记下 changeCount 让 watcher 跳过；
// 划词取词后还原剪贴板时加 nspasteboard.org 的 TransientType（transient），别的剪贴板工具不会把还原记成新条目。
// 用户主动的复制不加，照常进别的剪贴板工具。

import AppKit
import Carbon.HIToolbox

enum Paster {
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  /// 自家最近一次写入后的 changeCount
  private(set) static var ownChangeCount = -1

  /// 一次写完全部 item（每个 item 的多种表示也要一次写完，分两次 declare 会互相清空）
  static func write(_ items: [NSPasteboardItem], transient: Bool = false) {
    guard let first = items.first else { return }
    if transient { first.setData(Data(), forType: transientType) }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(items)
    ownChangeCount = pasteboard.changeCount
  }

  /// 单个 item 的多种表示
  static func write(_ representations: [NSPasteboard.PasteboardType: Data]) {
    let item = NSPasteboardItem()
    for (type, data) in representations { item.setData(data, forType: type) }
    write([item])
  }

  static func write(string: String) {
    write([.string: Data(string.utf8)])
  }

  /// 片段 {cursor} 最多往回挪这么多个字，再多就不挪（逐个发 ← 太久，用户也看得到光标在跑）
  static let maxCaretMoves = 500

  /// 向前台 App 发 ⌘V。浮层不激活本 App，前台一直是原 App，所以不用等待、不用切前台。
  /// movingLeft：片段 {cursor}，⌘V 之后紧接着按这么多次 ←，把光标挪回占位符处（超过 maxCaretMoves 不挪）。
  /// 未授权返回 false，内容仍留在剪贴板里
  static func pasteToFrontmost(movingLeft moves: Int = 0) -> Bool {
    guard Permissions.isAccessibilityTrusted else { return false }
    // ponytail: 按物理键位发 V（kVK_ANSI_V），Dvorak 这类布局下会变成别的键；真有人用再按布局查键码
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
      // 显式设 flags：热键里还按着的 ⌥ / ⇧ 不会混进来变成 ⌥⌘V / ⌘⇧V
      event?.flags = .maskCommand
      event?.post(tap: .cgSessionEventTap)
    }
    // 同一个事件源、flags 清空（不然成了 ⌘← 跳到行首）；事件按顺序排队，不加等待。
    // 某个 App 实测光标挪错时再为它加延迟，并注明是哪个 App（mac-overlay-panel §5）
    guard (1...maxCaretMoves).contains(moves) else { return true }
    for _ in 0..<moves {
      for keyDown in [true, false] {
        let event = CGEvent(
          keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: keyDown)
        event?.flags = []
        event?.post(tap: .cgSessionEventTap)
      }
    }
    return true
  }
}
