// 启动器的一条结果：App、内置动作、网址、文件路径（这四类记使用），以及网页搜索、关键词提示、计算结果、
// 「cb」那一行（不记）。
// id = 类型 + 目标，使用记录按它累计。内置动作副标题只写「Kitty Tools」，英文别名只进 names 参与匹配（N10）。

import Foundation
import UniformTypeIdentifiers

struct LauncherItem: Identifiable, Hashable {
  enum Kind: String {
    case app, action, url, path
    /// 网页搜索（目标是搜索页网址；不记使用，修旧版把搜索结果页记进频率，§11 #32）
    case search
    /// 计算结果：↩ 粘贴 payload
    case calculation
    /// 「cb [关键词]」那一行（目标是关键词）：↩ 呼出剪贴板面板并把关键词填进它的搜索框（N9）
    case clip
    /// 有关键词的网页搜索、文件搜索的提示：↩ / Tab 把「关键词 」补进输入框
    case prompt

    /// 只有这些记使用、能出现在「最近使用」里
    var isRecorded: Bool { [.app, .action, .url, .path].contains(self) }
  }

  let kind: Kind
  /// App / 文件的路径、网址、内置动作 id（存进使用记录，改名会丢记录）
  let target: String
  let title: String
  let subtitle: String
  /// 参与匹配的名字（已折叠）：标题、文件名、中文名、拼音全拼
  var names: [String] = []
  /// 首字母缩写（已折叠）：Visual Studio Code → vsc，活动监视器 → hdjsq
  var initials: [String] = []
  /// ↩ 粘贴的内容（计算结果）
  var payload: String?
  /// Tab 补进输入框的文字（计算结果、目录路径、「关键词 」）；nil 时 App、动作、网址补标题
  var completion: String?
  /// 文件搜索的结果：Spotlight 给的类型。图标、右侧种类按它取，不碰文件本身（桌面 / 文稿 / 下载里的文件
  /// 读图标、stat 都可能弹授权框）；有它的才算文件搜索结果（find 模式下 ↩ 在访达中显示）
  var contentType: UTType?

  var id: String { kind.rawValue + "\n" + target }

  /// 内置动作：只放本 App 已有的功能
  static let actions: [LauncherItem] = [
    action("clipboard", "剪贴板历史", "Clipboard"),
    action("translate-input", "输入翻译", "Translate"),
    action("screenshot", "截图", "Screenshot Capture"),
    action("translate-screenshot", "截图翻译", "Screenshot Translate"),
    action("ocr", "识字", "OCR Recognize Text QR"),
    action("settings", "设置", "Settings Preferences"),
  ]

  private static func action(_ id: String, _ title: String, _ alias: String) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(title)
    return LauncherItem(
      kind: .action, target: id, title: title, subtitle: "Kitty Tools",
      names: [title, alias, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [LauncherMatch.initials(alias), pinyin?.initials].compactMap { $0 })
  }

  var symbol: String {
    switch (kind, target) {
    case (.action, "clipboard"): "doc.on.clipboard"
    case (.action, "translate-input"): "character.bubble"
    case (.action, "screenshot"): "camera.viewfinder"
    case (.action, "translate-screenshot"): "text.viewfinder"
    case (.action, "ocr"): "doc.text.viewfinder"
    case (.action, _): "gearshape"
    case (.url, _): "globe"
    case (.search, _), (.prompt, _): "magnifyingglass"
    case (.calculation, _): "equal.square"
    case (.clip, _): "doc.on.clipboard"
    default: "doc"
    }
  }

  /// 对应的全局热键：内置动作和 cb 那一行选中时右侧显示它的键帽（N10）
  var hotKeyAction: HotKeyAction? {
    switch (kind, target) {
    case (.action, "clipboard"), (.clip, _): .clipboard
    case (.action, "translate-input"): .inputTranslate
    case (.action, "screenshot"): .screenshot
    case (.action, "translate-screenshot"): .screenshotTranslate
    case (.action, "ocr"): .recognizeText
    default: nil
    }
  }
}
