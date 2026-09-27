// 系统授权：辅助功能（粘贴回原 App 模拟 ⌘V、划词读 AX / 模拟 ⌘C）、屏幕录制（截图翻译截屏）、
// 文件和文件夹（启动器文件搜索：Spotlight 只给本 App 能访问的文件夹里的结果）、自动化（启动器系统命令让访达清倒
// 废纸篓、让 loginwindow 弹退出登录 / 重新启动 / 关机框；第一次用时系统自己弹框问，这里只负责被拒后打开系统设置）。

import AppKit
import ApplicationServices

enum Permissions {
  /// 提示里「去系统设置授权」按钮要打开的那一项
  enum Kind {
    case accessibility, screenRecording, filesAndFolders, automation

    var settingsTitle: String {
      switch self {
      case .accessibility: "打开辅助功能设置"
      case .screenRecording: "打开屏幕录制设置"
      case .filesAndFolders: "打开文件和文件夹设置"
      case .automation: "打开自动化设置"
      }
    }

    func openSettings() {
      let anchor =
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .automation: "Privacy_Automation"
        }
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

  /// 文件搜索要读的受保护文件夹（显示名, 相对主目录的路径）。实测 Spotlight 按调用方的授权过滤结果：
  /// 没授权时文稿、下载、iCloud 云盘里的文件一条都搜不到，也不会因此弹框
  static let protectedFolders = [
    ("桌面", "Desktop"), ("文稿", "Documents"), ("下载", "Downloads"),
    ("iCloud 云盘", "Library/Mobile Documents/com~apple~CloudDocs"),
  ]

  /// 没问过返回 nil（读一下目录就会弹框，所以问之前不碰）；问过之后返回被拒绝的文件夹（系统记住了答复，
  /// 再读不会弹框）
  static func deniedFolders() -> [String]? {
    guard UserDefaults.standard.bool(forKey: Prefs.folderAccessRequested) else { return nil }
    return protectedFolders.filter { !canOpen($0.1) }.map(\.0)
  }

  /// 逐个读目录，让系统依次弹「访问桌面 / 文稿 / 下载 / iCloud 云盘」授权框，返回被拒绝的。
  /// 每个框都要等用户点完才返回（主线程会停住）：只在用户点了「允许访问」时调用
  static func requestFolderAccess() -> [String] {
    UserDefaults.standard.set(true, forKey: Prefs.folderAccessRequested)
    return deniedFolders() ?? []
  }

  /// 目录不存在（没开 iCloud 云盘）不算被拒
  private static func canOpen(_ relativePath: String) -> Bool {
    guard let directory = opendir(NSHomeDirectory() + "/" + relativePath) else {
      return errno == ENOENT
    }
    closedir(directory)
    return true
  }
}
