// 偏好键名与默认值的唯一出处（PLAN §4）。键名沿用 Tauri 版的 camelCase，导入旧配置时一一对应。

import Foundation

enum Prefs {
  /// 剪贴板面板点外即关；面板上的图钉 = 把它关掉
  static let clipboardHideOnUnfocus = "clipboardHideOnUnfocus"
  /// 翻译浮窗固定：失焦不隐藏、Esc 不关闭
  static let floatingPinned = "floatingPinned"

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      clipboardHideOnUnfocus: true,
      floatingPinned: false,
    ])
  }
}
