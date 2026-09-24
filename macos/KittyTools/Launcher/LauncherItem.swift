// 启动器的一条结果：App、内置动作、网址、文件路径（这四类记使用），以及网页搜索、计算结果、剪贴板文本（不记）。
// id = 类型 + 目标，使用记录按它累计。

import Foundation

struct LauncherItem: Identifiable, Hashable {
  enum Kind: String {
    case app, action, url, path
    /// 网页搜索（目标是搜索页网址；不记使用，修旧版把搜索结果页记进频率，§11 #32）
    case search
    /// 计算结果、cb 列出的剪贴板文本：↩ 复制 payload
    case calculation, clip

    /// 只有这些记使用、能出现在「最近使用」里
    var isRecorded: Bool { [.app, .action, .url, .path].contains(self) }
  }

  let kind: Kind
  /// App / 文件的路径、网址、内置动作 id（沿用旧版 id，导入使用记录时直接对上）
  let target: String
  let title: String
  let subtitle: String
  /// 参与匹配的名字（已折叠）：标题、文件名、中文名、拼音全拼
  var names: [String] = []
  /// 首字母缩写（已折叠）：Visual Studio Code → vsc，活动监视器 → hdjsq
  var initials: [String] = []
  /// ↩ 复制的内容（计算结果、剪贴板全文）
  var payload: String?

  var id: String { kind.rawValue + "\n" + target }

  /// 内置动作：只放原生已有的功能（旧版的截图、贴图历史、开发者工具箱等到迁过来再加）
  static let actions: [LauncherItem] = [
    action("clipboard", "剪贴板历史", "Clipboard"),
    action("translate-input", "输入翻译", "Translate"),
    action("translate-screenshot", "截图翻译", "Screenshot Translate OCR"),
    action("settings", "设置", "Settings Preferences"),
  ]

  private static func action(_ id: String, _ title: String, _ alias: String) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(title)
    return LauncherItem(
      kind: .action, target: id, title: title, subtitle: "Kitty Tools · \(alias)",
      names: [title, alias, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [LauncherMatch.initials(alias), pinyin?.initials].compactMap { $0 })
  }

  var symbol: String {
    switch (kind, target) {
    case (.action, "clipboard"): "doc.on.clipboard"
    case (.action, "translate-input"): "character.bubble"
    case (.action, "translate-screenshot"): "text.viewfinder"
    case (.action, _): "gearshape"
    case (.url, _): "globe"
    case (.search, _): "magnifyingglass"
    case (.calculation, _): "equal.square"
    case (.clip, _): "doc.on.clipboard"
    default: "doc"
    }
  }
}
