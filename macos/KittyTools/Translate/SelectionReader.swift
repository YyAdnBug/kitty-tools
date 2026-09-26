// 划词取词：先用辅助功能（AX）直接读前台 App 的选中文本；读不到再「备份剪贴板 → 清空 → 发 ⌘C →
// 等剪贴板变化（最多约 500ms）→ 读文本 → 还原剪贴板」。和 C API 打交道的代码只在这里。
// 调用方保证：取词完成前不显示翻译浮窗（先显示会取消原 App 的选区，⌘C 拿到空内容）。

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum SelectionReader {
  static func read(pausing watcher: ClipboardWatcher) async -> String? {
    if let text = await accessibilitySelection() { return text }
    return await copySelection(pausing: watcher)
  }

  /// AX 直接读：不碰剪贴板。Chromium / Electron 系的 App 常常读不到，才需要 ⌘C 兜底
  @concurrent nonisolated static func accessibilitySelection() async -> String? {
    let system = AXUIElementCreateSystemWide()
    // 目标 App 卡住时 AX 调用会一直等：限 0.5 秒
    AXUIElementSetMessagingTimeout(system, 0.5)
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(system, "AXFocusedUIElement" as CFString, &focused) == .success,
      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return nil }
    let element = unsafeDowncast(focused, to: AXUIElement.self)
    var selected: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, "AXSelectedText" as CFString, &selected) == .success,
      let text = selected as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }

  /// ⌘C 兜底。期间暂停剪贴板采集（这次复制和还原都不是用户的复制）；原剪贴板内容按 item 逐项还原。
  /// ponytail: 只能还原当时已提供的数据，「延迟提供」的类型（promised data）还原不全
  private static func copySelection(pausing watcher: ClipboardWatcher) async -> String? {
    guard Permissions.isAccessibilityTrusted else { return nil }
    let pasteboard = NSPasteboard.general
    watcher.pause()
    defer { watcher.resume() }
    let backup = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    pasteboard.clearContents()
    let cleared = pasteboard.changeCount
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      let event = CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
      event?.flags = .maskCommand  // 热键里还按着的 ⌥ / ⇧ 不能混进来
      event?.post(tap: .cgSessionEventTap)
    }
    for _ in 0..<40 where pasteboard.changeCount == cleared {
      try? await Task.sleep(for: .milliseconds(12))
    }
    let text = pasteboard.changeCount == cleared ? nil : pasteboard.string(forType: .string)
    if backup.isEmpty { pasteboard.clearContents() } else { Paster.write(backup, transient: true) }
    return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
  }
}
