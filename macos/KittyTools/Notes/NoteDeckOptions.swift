// 屏幕边缘那叠的设置（设置 › 便签「屏幕边缘」；PLAN §10「便签」第 3 批）：读一次偏好、之后都传值。
// 键和注册的默认值在 Prefs（notesDeck*）：13 个是设置（跟着设置的导出走），纵向位置、指定的是哪块显示器是这台电脑
// 自己的状态（不注册默认值）。没存过的、不在档位里的值都按默认算——导入的文件、手改的偏好都可能带进怪值。
// 用它的：Prefs（默认值）、NotesTab（设置页）、NoteEdge / NoteDeck / NoteDeckLayout（摆放和排法）。

import Foundation

/// 设置 › 便签「屏幕边缘」
nonisolated struct NoteDeckOptions: Equatable, Sendable {
  enum Edge: String, CaseIterable, Sendable {
    case right, left

    var opposite: Edge { self == .right ? .left : .right }
    /// 界面上的叫法（「便签在屏幕右边缘」）
    var name: String { self == .right ? "右" : "左" }
  }

  /// 放在哪块显示器：主显示器 / 所有 / 指定的那一块（按名字认，它不在时退回主显示器）。
  /// ponytail: 名字是 NSScreen.localizedName，同型号的第二块起加序号（NoteDeckLayout.uniqueNames：「DELL」「DELL 2」）——
  /// 按接着的顺序认，两块同型号的换了接口可能对调；要认死得换成显示器的 UUID（CoreGraphics 的 C 接口）
  enum Display: Hashable, Sendable {
    case main, all
    case named(String)
  }

  /// 偏好里存的「显示器」那一项（Prefs.notesDeckDisplay）：指定的是哪一块在另一个键里（notesDeckChosenDisplay，
  /// 这台电脑自己的状态）
  enum DisplayMode: String, CaseIterable, Sendable {
    case main, all, chosen
  }

  /// 标签的样式（不叫 Style：那是全 App 设计刻度的名字，Shell/Style.swift）
  enum TabStyle: String, CaseIterable, Sendable {
    /// 带标题的标签（默认）/ 只有色块
    case tabs, chips
  }

  enum Size: String, CaseIterable, Sendable {
    case small, standard, large

    var scale: CGFloat {
      switch self {
      case .small: 0.85
      case .standard: 1
      case .large: 1.25
      }
    }
  }

  /// 打开的便签多大（连它带着的那张标签一起算）
  enum NoteSize: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    var size: CGSize {
      switch self {
      case .small: CGSize(width: 400, height: 320)
      case .medium: CGSize(width: 460, height: 380)
      case .large: CGSize(width: 560, height: 470)
      case .extraLarge: CGSize(width: 680, height: 560)
      }
    }
  }

  /// 感应范围的档位（点）：窄 / 标准 / 宽 / 很宽
  static let senseChoices = [8, 14, 28, 44]

  var isEnabled = true
  var edge = Edge.right
  var display = Display.main
  var style = TabStyle.tabs
  var size = Size.standard
  /// 鼠标离屏幕边缘多近就扇出
  var sense: CGFloat = 14
  var alwaysFanned = false
  var hidesPill = false
  var showsPreview = true
  var opensOnHover = false
  var overFullScreen = false
  var noteSize = NoteSize.medium
  /// 药丸的纵向位置：0 = 可见区最上，1 = 最下
  var position = 0.5

  init() {}

  /// 读偏好。没存过的（单测的临时偏好域里没有注册默认值）、不在档位里的都按默认算
  init(_ defaults: UserDefaults) {
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key) as? Bool ?? fallback
    }
    func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T
    where T.RawValue == String {
      defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
    // 便签这个功能关着（Feature）时那叠也不出现：NoteEdge 看着偏好变化，自己收起 / 摆回来
    isEnabled = flag(Prefs.notesDeckEnabled, true) && flag(Feature.notes.prefsKey, true)
    edge = choice(Prefs.notesDeckEdge, .right)
    let mode: DisplayMode = choice(Prefs.notesDeckDisplay, .main)
    switch mode {
    case .main: display = .main
    case .all: display = .all
    case .chosen:
      // 只说了「指定」没说是哪块 = 主显示器
      display = defaults.string(forKey: Prefs.notesDeckChosenDisplay).map(Display.named) ?? .main
    }
    style = choice(Prefs.notesDeckStyle, .tabs)
    size = choice(Prefs.notesDeckSize, .standard)
    let stored = defaults.object(forKey: Prefs.notesDeckSense) as? Int ?? 14
    sense = CGFloat(Self.senseChoices.contains(stored) ? stored : 14)
    alwaysFanned = flag(Prefs.notesDeckAlwaysFanned, false)
    hidesPill = flag(Prefs.notesDeckHidesPill, false)
    showsPreview = flag(Prefs.notesDeckPreview, true)
    opensOnHover = flag(Prefs.notesDeckOpensOnHover, false)
    overFullScreen = flag(Prefs.notesDeckOverFullScreen, false)
    noteSize = choice(Prefs.notesDeckNoteSize, .medium)
    let ratio = defaults.object(forKey: Prefs.notesDeckPosition) as? Double ?? 0.5
    position = ratio.isFinite ? min(max(ratio, 0), 1) : 0.5
  }
}
