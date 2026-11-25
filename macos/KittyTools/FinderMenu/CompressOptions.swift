// 访达右键「压缩为 ▸ 其他格式和选项…」的小面板（2026-11-25 格式扩充拍板 U1–U7，第 2 批）：一个系统确认框，下面挂格式、压缩级别、
// 「分别压缩每一项」。子菜单里 ZIP / 7Z / TAR.GZ 照旧一键（级别「标准」）；少见的格式和选项收在这里（照几家压缩软件的选项收的：
// 排除 Mac 资源文件一直开着、不给开关，验证并进「压完把原件移到废纸篓」，见拍板 U6 U7）。
// 框经 FinderLink.ask 弹（提到最前、关了把前台还给访达；扩展交过来时已经激活了本 App，键盘直接能用）。
// 上次选的格式、级别、分别压缩记在偏好里（这台电脑自己的界面状态，不注册默认值、不导出不同步，同 finderLastSuffix）。
// 屏外截图自检（SnapshotProbeTests.finderMenuSettings，图 finder-compress-*）用 panel 画同一个框。

import AppKit

@MainActor enum CompressOptions {
  /// 框里选好的
  struct Choice: Equatable {
    var format: Archives.Format
    var level: Archives.Level
    var separately: Bool
  }

  /// 下拉里的顺序（常用的在前）
  nonisolated static let formats: [Archives.Format] = [
    .zip, .sevenZip, .tarGz, .tarBz2, .tarXz, .tar, .dmg, .iso,
  ]

  /// 格式下面那一行小字：谁打得开、什么时候用
  nonisolated static func hint(for format: Archives.Format) -> String {
    switch format {
    case .zip: String(localized: "哪儿都能直接打开")
    case .sevenZip: String(localized: "比 ZIP 小；Mac 和 Windows 11 自带的工具都能打开")
    case .tarGz: String(localized: "Linux 和开发者常用")
    case .tarBz2: String(localized: "比 TAR.GZ 小一点、慢一点")
    case .tarXz: String(localized: "比 TAR.GZ 小得多，也慢得多")
    case .tar: String(localized: "不压缩，只打成一个包；照片、视频这类已经压过的最快")
    case .dmg: String(localized: "磁盘映像，Mac 上双击就能打开")
    case .iso: String(localized: "光盘映像，给虚拟机、刻录用")
    }
  }

  /// 上次的选择（没存过、存的认不出来：ZIP、标准、不分别）
  static var last: Choice {
    let defaults = UserDefaults.standard
    return Choice(
      format: defaults.string(forKey: Prefs.finderCompressFormat).flatMap(Archives.Format.init)
        ?? .zip,
      level: defaults.string(forKey: Prefs.finderCompressLevel).flatMap(Archives.Level.init)
        ?? .normal,
      separately: defaults.bool(forKey: Prefs.finderCompressSeparately))
  }

  /// 问；取消、已经开着一个框是 nil。items：选中的那几样（标题、要不要「分别压缩」）
  static func ask(for items: [URL]) -> Choice? {
    let panel = panel(for: items, start: last)
    let answer = withExtendedLifetime(panel.keep) {
      FinderLink.ask(panel.alert, focus: panel.focus)
    }
    guard answer == .alertFirstButtonReturn else { return nil }
    let choice = panel.choice()
    let defaults = UserDefaults.standard
    defaults.set(choice.format.rawValue, forKey: Prefs.finderCompressFormat)
    defaults.set(choice.level.rawValue, forKey: Prefs.finderCompressLevel)
    if items.count > 1 { defaults.set(choice.separately, forKey: Prefs.finderCompressSeparately) }
    return choice
  }

  /// 搭好的框：focus 是一打开就在的那个控件，choice 读回框里选的，keep 要一直拿着到框关掉（下拉的 target 是弱引用）
  static func panel(for items: [URL], start: Choice) -> (
    alert: NSAlert, focus: NSView, choice: () -> Choice, keep: AnyObject
  ) {
    let format = NSPopUpButton(frame: .zero, pullsDown: false)
    format.addItems(withTitles: formats.map(\.title))
    format.selectItem(at: formats.firstIndex(of: start.format) ?? 0)
    let level = NSPopUpButton(frame: .zero, pullsDown: false)
    level.addItems(withTitles: Archives.Level.allCases.map(\.title))
    level.selectItem(at: Archives.Level.allCases.firstIndex(of: start.level) ?? 1)
    // 每种格式能选的级别不一样（Archives.Format.levels）：不能选的那几项变灰
    level.autoenablesItems = false
    let note = NSTextField(wrappingLabelWithString: "")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 240
    let separately = NSButton(
      checkboxWithTitle: String(localized: "分别压缩每一项（\(items.count) 个包）"), target: nil,
      action: nil)
    separately.state = start.separately ? .on : .off

    // 换格式：小字跟着换，不压缩的两种（TAR、ISO）级别变灰
    let refresh = Target {
      let chosen = formats[max(format.indexOfSelectedItem, 0)]
      note.stringValue = hint(for: chosen)
      level.isEnabled = chosen.hasLevels
      for (index, candidate) in Archives.Level.allCases.enumerated() {
        level.item(at: index)?.isEnabled = chosen.levels.contains(candidate)
      }
      // 选着的这一档这种格式没有：换成标准
      if chosen.hasLevels,
        !chosen.levels.contains(Archives.Level.allCases[max(level.indexOfSelectedItem, 0)])
      {
        level.selectItem(at: Archives.Level.allCases.firstIndex(of: .normal) ?? 1)
      }
    }
    format.target = refresh
    format.action = #selector(Target.fire)
    refresh.fire()

    let formatLabel = NSTextField(labelWithString: String(localized: "格式："))
    let levelLabel = NSTextField(labelWithString: String(localized: "压缩级别："))
    format.setAccessibilityTitleUIElement(formatLabel)
    level.setAccessibilityTitleUIElement(levelLabel)
    let grid = NSGridView(views: [
      [formatLabel, format],
      [NSGridCell.emptyContentView, note],
      [levelLabel, level],
      [NSGridCell.emptyContentView, separately],
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.rowSpacing = 8
    // 只选了一样：没有「分别压缩」这一行
    grid.row(at: 3).isHidden = items.count < 2
    // 框的大小按最长的那句小字量：换格式时框不会跟着变高（评审），每种都试一遍、取最大的
    var size = NSSize.zero
    for candidate in formats {
      note.stringValue = hint(for: candidate)
      let fit = grid.fittingSize
      size = NSSize(width: max(size.width, fit.width), height: max(size.height, fit.height))
    }
    refresh.fire()
    grid.frame.size = size

    let alert = NSAlert()
    alert.messageText =
      items.count == 1
      ? String(localized: "压缩「\(items[0].lastPathComponent)」")
      : String(localized: "压缩 \(items.count) 项")
    alert.informativeText = String(localized: "压缩包放在旁边，重名时名字加「 2」。")
    alert.addButton(withTitle: String(localized: "压缩"))
    // Esc = 取消
    alert.addButton(withTitle: String(localized: "取消")).keyEquivalent = "\u{1b}"
    alert.accessoryView = grid
    let choice = {
      Choice(
        format: formats[max(format.indexOfSelectedItem, 0)],
        level: Archives.Level.allCases[max(level.indexOfSelectedItem, 0)],
        separately: items.count > 1 && separately.state == .on)
    }
    return (alert, format, choice, refresh)
  }

  /// 下拉换了选项时叫一个闭包（NSPopUpButton 的 target 要是 @objc 对象）
  private final class Target: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
  }
}
