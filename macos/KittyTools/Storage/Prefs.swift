// 偏好键名与默认值的唯一出处（PLAN §4）。键名字符串沿用旧版 camelCase，M4 导入旧配置时一一对应。

import Foundation

enum Prefs {
  /// 剪贴板面板点外即关；面板上的图钉 = 把它关掉
  static let clipboardHideOnUnfocus = "clipboardHideOnUnfocus"
  /// 翻译浮窗固定：失焦不隐藏、Esc 不关闭
  static let floatingPinned = "floatingPinned"

  /// 普通历史（非收藏 / 片段 / 分组）最多保留几条，0 = 不限
  static let clipboardHistoryMax = "clipboardHistoryMax"
  /// 普通历史保留天数，0 = 永久
  static let clipboardRetentionDays = "clipboardHistoryRetentionDays"
  /// 图片总占用上限（MB），0 = 不限；超出时从最旧的普通图片开始删
  static let clipboardImageBudgetMB = "clipboardImageCacheMaxMb"
  /// 来源 App 名称或 bundle ID 包含这些关键词就不记录
  static let clipboardExcludedApps = "clipboardExcludedApps"
  static let clipboardBlockSensitive = "clipboardBlockSensitive"
  static let clipboardKeepRichText = "clipboardKeepRichText"
  static let clipboardImageOCR = "clipboardImageOcr"
  static let clipboardClearOnQuit = "clipboardClearOnExit"
  static let clipboardClearOnLock = "clipboardClearOnLock"
  static let clipboardShowPreview = "clipboardShowPreview"

  /// 源语言：没设 = 自动检测
  static let translateSource = "translateSourceLang"
  /// 目标语言：没设 = 智能（母语 ⇄ 常用外语）
  static let translateTarget = "translateTargetLang"
  static let translateNative = "translateNativeLang"
  static let translateForeign = "translateForeignLang"
  static let translateRemoveNewlines = "translateDeleteNewline"
  /// 自动复制第一个服务的译文
  static let translateAutoCopy = "autoCopy"
  static let translateHistoryEnabled = "translateHistoryEnabled"
  static let translateHistoryLimit = "translateHistoryLimit"
  /// 复制即译：复制文本后自动弹出翻译浮窗（不抢键盘）
  static let translateCopyToTranslate = "translateClipboardMonitor"

  /// 上次启动的版本号：没有 = 首次安装（打开通用页），和当前不同 = 刚更新（打开关于页看更新内容）
  static let lastSeenVersion = "lastSeenVersion"

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      clipboardHideOnUnfocus: true,
      floatingPinned: false,
      clipboardHistoryMax: 100,
      clipboardRetentionDays: 7,
      clipboardImageBudgetMB: 1024,
      // 密码管理器大多会打 ConcealedType 标记，这里兜底；「密码」是 macOS 15 自带的 Passwords
      clipboardExcludedApps: [
        "1Password", "Bitwarden", "KeePass", "Keychain", "钥匙串", "com.apple.Passwords",
      ],
      clipboardBlockSensitive: true,
      clipboardKeepRichText: true,
      clipboardImageOCR: true,
      clipboardClearOnQuit: false,
      clipboardClearOnLock: false,
      clipboardShowPreview: true,
      translateNative: Lang.zhHans.rawValue,
      translateForeign: Lang.en.rawValue,
      translateRemoveNewlines: false,
      translateAutoCopy: false,
      translateHistoryEnabled: true,
      translateHistoryLimit: 500,
      translateCopyToTranslate: false,
    ])
  }
}
