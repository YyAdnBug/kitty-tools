// 自家写剪贴板与模拟粘贴的唯一出口（mac-native §5）。写入后记下 changeCount 让 watcher 跳过；
// 划词取词后还原剪贴板时加 nspasteboard.org 的 TransientType（transient），别的剪贴板工具不会把还原记成新条目。
// 用户主动的复制不加，照常进别的剪贴板工具。
// 本 App 生成的新文字（译文、原文、计算结果、路径 / 网址、替换原文、识字、取色…）用 write(string:record: true)
// 写并同时记进剪贴板历史（recordText）；从历史取出的已有条目、划词还原、剪贴板面板里的色值块不记。

import AppKit
import Carbon.HIToolbox

enum Paster {
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  /// 自家最近一次写入后的 changeCount
  private(set) static var ownChangeCount = -1
  /// 用户在自家浮层里 ⌘C / ⌘X 之后的 changeCount（走 NSText.copy，不经 write）：照常记进历史，但没有来源、
  /// 不触发复制即译（体检 B20）。在复制那一刻记，不在轮询时看 key 窗口猜（轮询前浮层可能已收起、或别处已打开浮层）
  static var panelCopyChangeCount = -1

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

  /// 把本 App 生成的一段文字记进剪贴板历史：AppDelegate 启动时接到 `ClipboardStore.recordOwnText`（过敏感文本过滤、
  /// 已有同文只挪到最前）；单测里没接，是 nil，不记
  static var recordText: ((String) -> Void)?

  /// record：这段文字是本 App 生成的新内容（watcher 会跳过自家写入，所以自己记）。
  /// 从历史里取出的条目、划词还原、剪贴板面板开着时的色值块传 false（面板开着时记新条目会把选中跳走）
  static func write(string: String, record: Bool = false) {
    write([.string: Data(string.utf8)])
    if record { recordText?(string) }
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
