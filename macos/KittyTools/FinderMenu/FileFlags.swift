// 访达右键「显示 / 隐藏 隐藏文件」「隐藏」「取消隐藏」「隐藏扩展名」「显示扩展名」（2026-11-08 右键扩充第 3 批，拍板 E1 E2，默认都关）。
// - 显示 / 隐藏 隐藏文件：替用户在访达里按一下 ⇧⌘.（要辅助功能授权，没有就刘海岛说一声、带「去授权」），不重启访达——
//   重启会打断正在进行的拷贝。访达不在最前面就先叫到前面、等它到了再按（同 NewFile.revealForRename）。
//   ponytail: 菜单里只有一项切换，不分「显示」「不显示」：没查实 ⇧⌘. 会不会写进访达的 AppleShowAllFiles 偏好（扩展也读不到），
//   真机确认了再按状态分两种叫法（HANDTEST「访达右键手测」）。
// ponytail: 按的是美式键盘上「.」那个位置的键（kVK_ANSI_Period），法语这类布局上那个键不是「.」；看到访达在最前面再投给整个
//   会话，中间有极短的空档。有人报了再按当前布局反查键码、改成只投给访达。
// - 隐藏 / 取消隐藏：设文件的隐藏标记（isHidden，同 chflags hidden）；点开头的文件本来就是隐藏的，不动它；卷的根、主目录、
//   第一层的系统文件夹不动（FileMoves.protected：外接盘藏起来就从桌面上没了）。符号链接改的是链接本身（评审实测）。
// - 隐藏 / 显示扩展名：同「显示简介」里的「隐藏扩展名」（hasHiddenExtension）。
// 扩展看选中的现在是什么样决定叫哪个（读不到就当没隐藏）；App 照网址里说的做（on=1 / 0），做完刘海岛说一声。

import AppKit
import Carbon.HIToolbox

@MainActor enum FileFlags {
  static func toggleHiddenFiles(island: Island?) {
    guard Permissions.isAccessibilityTrusted else {
      island?.show(
        "要「辅助功能」授权", detail: "授权后才能替你在访达里按 ⇧⌘.", tone: .warning,
        actions: [Island.Action("去授权", opens: true) { Permissions.openAccessibilitySettings() }])
      return
    }
    let finderIsFront = {
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    Task {
      if !finderIsFront() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
          .activate()
        for _ in 0..<40 where !finderIsFront() {
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
      guard finderIsFront() else {
        NSSound.beep()
        return
      }
      Paster.press(kVK_ANSI_Period, flags: [.maskCommand, .maskShift])
    }
  }

  /// 隐藏 / 取消隐藏（点开头的跳过）
  static func setHidden(_ files: [URL], _ hidden: Bool, island: Island?) {
    let changed = change(
      files.filter { !$0.lastPathComponent.hasPrefix(".") && !FileMoves.protected($0) }
    ) {
      $0.isHidden = hidden
    }
    guard changed > 0 else {
      NSSound.beep()
      return
    }
    island?.show(
      (hidden ? "已隐藏" : "已取消隐藏") + (changed == 1 ? "" : " \(changed) 项"),
      detail: hidden ? "在访达里按 ⇧⌘. 能看到隐藏的东西" : nil)
  }

  /// 隐藏 / 显示扩展名
  static func setExtensionHidden(_ files: [URL], _ hidden: Bool, island: Island?) {
    let changed = change(files.filter { !$0.pathExtension.isEmpty }) {
      $0.hasHiddenExtension = hidden
    }
    guard changed > 0 else {
      NSSound.beep()
      return
    }
    island?.show(
      (hidden ? "已隐藏扩展名" : "已显示扩展名") + (changed == 1 ? "" : "（\(changed) 项）"))
  }

  /// 给每一样设一下属性；返回设成了几样
  private static func change(_ files: [URL], _ set: (inout URLResourceValues) -> Void) -> Int {
    var changed = 0
    for file in files where FileMoves.occupied(file) {
      var url = file
      var values = URLResourceValues()
      set(&values)
      if (try? url.setResourceValues(values)) != nil { changed += 1 }
    }
    return changed
  }
}
