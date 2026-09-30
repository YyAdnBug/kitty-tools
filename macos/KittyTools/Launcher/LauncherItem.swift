// 启动器的一条结果：App、内置动作、网址（含系统设置面板、浏览历史）、文件路径、系统命令（这五类记使用、能收藏），
// 以及网页搜索、关键词提示、计算结果、「cb」「fy」那一行、kill 列的进程（不记）。
// id = 类型 + 目标，使用记录按它累计。内置动作和菜单栏同一份（体检 A26）：副标题只写「Kitty Tools」（两个开关写开没开），
// 英文别名只进 names 参与匹配（N10）。

import Foundation
import UniformTypeIdentifiers

struct LauncherItem: Identifiable, Hashable {
  enum Kind: String {
    case app, action, url, path
    /// 系统命令（锁定屏幕、清倒废纸篓…，目标是 Alfred 关键词，见 SystemCommands）
    case system
    /// 网页搜索（目标是搜索页网址；不记使用，修旧版把搜索结果页记进频率，§11 #32）
    case search
    /// 计算结果：↩ 粘贴 payload
    case calculation
    /// 「cb [关键词]」那一行（目标是关键词）：↩ 呼出剪贴板面板并把关键词填进它的搜索框（N9）
    case clip
    /// 有关键词的网页搜索、文件搜索的提示：↩ / Tab 把「关键词 」补进输入框
    case prompt
    /// 「fy 文本」那一行（目标是文本）：↩ 收起启动器、翻译浮窗直接翻译（体检 D10）
    case translate
    /// 「kill 空格」列的后台进程（目标是 PID，体检 D12）：↩ 结束、⌘↩ 强制结束
    case process

    /// 只有这些记使用、能出现在「常用」里、能收藏
    var isRecorded: Bool { [.app, .action, .url, .path, .system].contains(self) }
  }

  let kind: Kind
  /// App / 文件的路径、网址、内置动作 id、系统命令关键词（存进使用记录，改名会丢记录）
  let target: String
  let title: String
  /// 浏览历史搜到时拼上「3 天前」（按搜的那一刻算）
  var subtitle: String
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
  /// 浏览历史：最后访问的时间（副标题的「3 天前」按它算）
  var visitedAt: Date?

  var id: String { kind.rawValue + "\n" + target }

  /// 内置动作此刻的状态（AppDelegate 在每次搜索时给）：暂停记录剪贴板了没有、复制即译开没开、钉图（nil = 没有钉图，
  /// true = 藏着）、能不能检查更新（正式版）、在不在录屏（录着时「录屏」那一项是「停止录屏」）
  struct ActionState: Equatable {
    var recordingPaused = false
    var copyToTranslate = false
    var pinsHidden: Bool?
    var checksUpdates = false
    var screenRecording = false
  }

  /// 内置动作（体检 A26）：和菜单栏同名同序——按 HotKeyAction.sections（启动器自己除外），每节末尾接上那一节的
  /// MenuExtra（暂停记录剪贴板、复制即译、有钉图时的两项），最后设置、快捷键速查表、关于、检查更新（正式版）、
  /// 退出 Kitty Tools（菜单栏图标隐藏时只剩这里能退出，第 9 批 M1）。
  /// 老的 6 个 id 保留（使用记录按 id 累计），新加的用 HotKeyAction.rawValue / MenuExtra.rawValue。
  /// 按状态缓存：每敲一个字都要列一遍，拼音转写不便宜
  static func actions(_ state: ActionState = .init()) -> [LauncherItem] {
    if let cached = actionCache, cached.state == state { return cached.items }
    var items: [LauncherItem] = []
    let extras = MenuExtra.allCases.filter { $0.isAvailable(state) }
    for section in HotKeyAction.sections {
      for hotKey in section.actions where hotKey != .launcher {
        items.append(
          action(
            actionID(hotKey), hotKey.title(recording: state.screenRecording), aliases[hotKey] ?? "")
        )
      }
      for extra in extras where section.actions.contains(where: { $0 == extra.section }) {
        items.append(action(extra, state))
      }
    }
    items += extras.filter { $0.section == nil }.map { action($0, state) }
    actionCache = (state, items)
    return items
  }

  /// 菜单栏那一项的启动器版：标题去掉菜单的「…」，开关写开没开
  private static func action(_ extra: MenuExtra, _ state: ActionState) -> LauncherItem {
    let subtitle =
      switch (extra, extra.isOn(state)) {
      case (.pauseClipboard, let on?): on ? "已暂停" : "正在记录"
      case (_, let on?): on ? "已开启" : "已关闭"
      default: "Kitty Tools"
      }
    return action(
      extra.rawValue, extra.title(pinsHidden: state.pinsHidden == true).replacing("…", with: ""),
      extra.alias, subtitle: subtitle)
  }

  private static var actionCache: (state: ActionState, items: [LauncherItem])?

  /// 对得上全局热键的内置动作的 id：老的 5 个沿用旧名（使用记录按 id 累计，改名会丢），新加的用 rawValue
  static func actionID(_ action: HotKeyAction) -> String {
    switch action {
    case .clipboard: "clipboard"
    case .inputTranslate: "translate-input"
    case .screenshot: "screenshot"
    case .screenshotTranslate: "translate-screenshot"
    case .recognizeText: "ocr"
    default: action.rawValue
    }
  }

  /// 英文别名（只进 names）
  private static let aliases: [HotKeyAction: String] = [
    .clipboard: "Clipboard History", .selectionTranslate: "Selection Translate",
    .inputTranslate: "Translate Input", .translateReplace: "Translate Replace",
    .screenshotTranslate: "Screenshot Translate", .screenshot: "Screenshot Capture",
    .screenshotLastRegion: "Capture Last Region", .recognizeText: "OCR Recognize Text QR",
    .screenRecord: "Screen Recording Record Video",
  ]

  private static func action(
    _ id: String, _ title: String, _ alias: String, subtitle: String = "Kitty Tools"
  ) -> LauncherItem {
    let pinyin = AppCatalog.pinyin(title)
    return LauncherItem(
      kind: .action, target: id, title: title, subtitle: subtitle,
      names: [title, alias, pinyin?.full].compactMap { $0.map(LauncherMatch.fold) },
      initials: [LauncherMatch.initials(alias), pinyin?.initials].compactMap { $0 })
  }

  var symbol: String {
    // 对得上全局热键的内置动作（和 cb 那一行）用 HotKeyAction 的符号：和菜单栏、快捷键页是同一个图标
    if kind == .action || kind == .clip, let action = hotKeyAction { return action.symbol }
    return switch (kind, target) {
    case (.action, _): MenuExtra(rawValue: target)?.symbol ?? "gearshape"
    case (.translate, _): "character.bubble.fill"
    case (.system, _): SystemCommand(rawValue: target)?.symbol ?? "power"
    case (.process, _): "terminal.fill"
    case (.url, _): "globe"
    case (.search, _), (.prompt, _): "magnifyingglass"
    case (.calculation, _): "equal.square"
    default: "doc"
    }
  }

  /// 对应的全局热键：内置动作、cb 那一行（剪贴板）、fy 那一行（输入翻译）选中时右侧显示它的键帽（N10）
  var hotKeyAction: HotKeyAction? {
    switch kind {
    case .clip: .clipboard
    case .translate: .inputTranslate
    case .action: HotKeyAction.allCases.first { Self.actionID($0) == target }
    default: nil
    }
  }
}
