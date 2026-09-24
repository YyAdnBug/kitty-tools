// 辅助功能授权：粘贴回原 App（模拟 ⌘V）和划词（AX 读选区 / 模拟 ⌘C）都依赖它。

import AppKit
import ApplicationServices

enum Permissions {
  static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  /// 未授权时弹系统授权框。系统只弹一次，之后要去系统设置里手动打开
  static func requestAccessibility() {
    // 用字面量而不是 kAXTrustedCheckOptionPrompt：后者是全局 var，Swift 6 下不算并发安全
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  static func openAccessibilitySettings() {
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    NSWorkspace.shared.open(URL(string: url)!)
  }
}
