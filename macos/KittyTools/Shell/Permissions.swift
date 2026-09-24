// 系统授权：辅助功能（粘贴回原 App 模拟 ⌘V、划词读 AX / 模拟 ⌘C）、屏幕录制（截图翻译截屏）。

import AppKit
import ApplicationServices

enum Permissions {
  /// 提示里「去系统设置授权」按钮要打开的那一项
  enum Kind {
    case accessibility, screenRecording

    var settingsTitle: String {
      switch self {
      case .accessibility: "打开辅助功能设置"
      case .screenRecording: "打开屏幕录制设置"
      }
    }

    func openSettings() {
      let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
  }

  static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

  /// 未授权时弹系统授权框。系统只弹一次，之后要去系统设置里手动打开
  static func requestAccessibility() {
    // 用字面量而不是 kAXTrustedCheckOptionPrompt：后者是全局 var，Swift 6 下不算并发安全
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  static func openAccessibilitySettings() { Kind.accessibility.openSettings() }

  /// 只检查、不弹框
  static var isScreenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

  /// 未授权时弹系统授权框（同样只弹一次）。截屏前先经这里，免得每块屏幕各弹一个框
  static func requestScreenRecording() { CGRequestScreenCaptureAccess() }
}
