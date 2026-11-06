// 截图时的快捷键（2026-11-06 用户：「截图之后的工具条支持自定义快捷键」；拍板页 A1–A5 全部按推荐）：
// 工具栏上看得到的都能改——十种标注工具、钉图、长截图、识字、录屏、拷贝、存储、另存为、撤销、重做，加上同样是单字母的
// 「上次区域」「取色」。Esc ↩ ⌫ Tab 空格、方向键、⌘D、标注遮罩的缩放键固定不改（reserved）。
// 截图框选（SelectionView）和标注遮罩（ScrollCanvas、AnnotateOverlay）用同一份；长截图面板没有工具栏，不变。
// 存在偏好的 shotkey.<名字>（同全局快捷键：组合的 JSON，空数据 = 清除了，没存过 = 默认），跟设置导出 / 导入、同步的
// 「快捷键」一类走（SettingsArchive 里记成 shot.<名字>，同步里是 shotkey:<名字>；0.7.2 及之前都不认、原样忽略）。
// 设置在 设置 › 快捷键「截图时」两组（HotkeysTab，录制框同 HotKeyRecorder）；工具栏悬停提示、HUD 菜单、速查表都按这里写键。

import AppKit
import Carbon.HIToolbox

enum ShotKey: String, CaseIterable {
  case rectangle, ellipse, arrow, line, pen, highlighter, text, counter, mosaic, spotlight
  case copy, save, saveAs, pin, recognize, scroll, record, undo, redo, lastRegion, pickColor

  /// 设置页的两组：十种标注工具，出图和别的
  static var tools: [ShotKey] { Annotation.Tool.allCases.map { ShotKey($0) } }
  static var others: [ShotKey] { allCases.filter { $0.tool == nil } }

  init(_ tool: Annotation.Tool) {
    self =
      switch tool {
      case .rectangle: .rectangle
      case .ellipse: .ellipse
      case .arrow: .arrow
      case .line: .line
      case .pen: .pen
      case .highlighter: .highlighter
      case .text: .text
      case .counter: .counter
      case .mosaic: .mosaic
      case .spotlight: .spotlight
      }
  }

  var tool: Annotation.Tool? {
    Annotation.Tool.allCases.first { ShotKey($0) == self }
  }

  var title: String {
    if let tool { return tool.title }
    return switch self {
    case .copy: "拷贝"
    case .save: "存储"
    case .saveAs: "另存为…"
    case .pin: "钉到屏幕"
    case .recognize: "识字并拷贝"
    case .scroll: "长截图"
    case .record: "录屏"
    case .undo: "撤销"
    case .redo: "重做"
    case .lastRegion: "选中上次的区域"
    case .pickColor: "复制放大镜里的色值"
    default: ""
    }
  }

  /// 设置页那一行的符号（和工具栏上的钮一样）
  var symbol: String {
    if let tool { return tool.symbol }
    return switch self {
    case .copy: "checkmark"
    case .save: "square.and.arrow.down"
    case .saveAs: "square.and.arrow.down.on.square"
    case .pin: "pin"
    case .recognize: "text.viewfinder"
    case .scroll: "rectangle.expand.vertical"
    case .record: "record.circle"
    case .undo: "arrow.uturn.backward"
    case .redo: "arrow.uturn.forward"
    case .lastRegion: "arrow.counterclockwise"
    case .pickColor: "eyedropper"
    default: "keyboard"
    }
  }

  /// 原来写死的那一套：1–0 工具，T S O R D C 单字母，⌘C ⌘S ⇧⌘S ⌘Z ⇧⌘Z
  var defaultKey: HotKey {
    let digits = [
      kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
      kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
    ]
    if let tool { return HotKey(keyCode: digits[tool.rawValue - 1], modifiers: 0) }
    let (code, modifiers) =
      switch self {
      case .copy: (kVK_ANSI_C, cmdKey)
      case .save: (kVK_ANSI_S, cmdKey)
      case .saveAs: (kVK_ANSI_S, cmdKey | shiftKey)
      case .pin: (kVK_ANSI_T, 0)
      case .recognize: (kVK_ANSI_O, 0)
      case .scroll: (kVK_ANSI_S, 0)
      case .record: (kVK_ANSI_R, 0)
      case .undo: (kVK_ANSI_Z, cmdKey)
      case .redo: (kVK_ANSI_Z, cmdKey | shiftKey)
      case .lastRegion: (kVK_ANSI_D, 0)
      case .pickColor: (kVK_ANSI_C, 0)
      default: (kVK_ANSI_1, 0)
      }
    return HotKey(keyCode: code, modifiers: modifiers)
  }

  /// 指向别的功能（录屏）：那个功能关着时设置页不列这一行
  var feature: Feature { self == .record ? .record : .screenshot }

  var prefsKey: String { "shotkey." + rawValue }

  /// 现在的键：没存过 = 默认，存了空数据 = 清除了（nil），解不出来的也当清除了
  func key(in defaults: UserDefaults = .standard) -> HotKey? {
    guard let data = defaults.data(forKey: prefsKey) else { return defaultKey }
    return try? JSONDecoder().decode(HotKey.self, from: data)
  }

  /// 存一个键（nil = 清除；和默认一样时删掉这个键，回到「没存过」）
  func set(_ key: HotKey?, in defaults: UserDefaults = .standard) {
    if key == defaultKey {
      defaults.removeObject(forKey: prefsKey)
    } else {
      defaults.set(HotKeyAction.stored(key), forKey: prefsKey)
    }
  }

  /// 悬停提示、菜单、速查表里写的键（清除了是 nil）
  var label: String? { key()?.display }

  /// 「名字（键）」：工具栏悬停提示；清除了就只写名字
  func tip(_ name: String) -> String { label.map { "\(name)（\($0)）" } ?? name }

  /// 这一下按键对应哪个动作（只比键位和 ⌘ ⌥ ⌃ ⇧，别的位不管）
  static func matching(_ event: NSEvent, in defaults: UserDefaults = .standard) -> ShotKey? {
    matching(HotKey(keyCode: event.keyCode, flags: event.modifierFlags), in: defaults)
  }

  static func matching(_ hotKey: HotKey, in defaults: UserDefaults = .standard) -> ShotKey? {
    allCases.first { $0.key(in: defaults) == hotKey }
  }

  /// 十种工具都是默认的 1–0（速查表那一行照旧写「1–0」，改过就逐个列）
  static func toolsAreDefault(in defaults: UserDefaults = .standard) -> Bool {
    tools.allSatisfy { $0.key(in: defaults) == $0.defaultKey }
  }

  // MARK: 能录什么

  /// 截图里另有用处、固定不改的键：Esc ↩ ⌫ Tab 空格、方向键（带什么修饰键都算）、⌘D（复制标注）、标注遮罩的缩放
  /// ⌘0 ⌘1 ⌘= ⇧⌘= ⌘- 和小键盘的 ⌘+ ⌘-。修饰键自己（连按两下那种）也不收
  static func isReserved(_ hotKey: HotKey) -> Bool {
    let code = Int(hotKey.keyCode)
    let anyModifiers: Set<Int> = [
      kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete, kVK_Tab,
      kVK_Space, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
    ]
    if anyModifiers.contains(code) || hotKey.doubleTap != nil { return true }
    if (54...63).contains(code) { return true }  // 修饰键、大写锁定、fn 的键位
    let fixed: Set<HotKey> = [
      HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_0, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_1, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_Equal, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_Equal, modifiers: cmdKey | shiftKey),
      HotKey(keyCode: kVK_ANSI_Minus, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_KeypadPlus, modifiers: cmdKey),
      HotKey(keyCode: kVK_ANSI_KeypadMinus, modifiers: cmdKey),
    ]
    return fixed.contains(hotKey)
  }

  /// 文件、同步里读进来的能不能用：键码、修饰键位在范围里，不是固定的键
  static func isUsable(_ hotKey: HotKey) -> Bool {
    hotKey.keyCode < 128
      && hotKey.modifiers & ~UInt32(cmdKey | shiftKey | optionKey | controlKey) == 0
      && !isReserved(hotKey)
  }

  /// 给 shotKey 录 hotKey 行不行：不行返回那一行下面的橙字（A2：固定的键、截图里重复、和全局快捷键一样）
  static func problem(
    with hotKey: HotKey, for shotKey: ShotKey, in defaults: UserDefaults = .standard
  ) -> String? {
    if isReserved(hotKey) {
      return "这个键在截图里另有用处（Esc、↩、⌫、Tab、空格、方向键、⌘D、缩放），换一个"
    }
    if let other = allCases.first(where: { $0 != shotKey && $0.key(in: defaults) == hotKey }) {
      return "和截图里的「\(other.title)」重复"
    }
    let globals = HotKeyAction.allCases.filter(\.isAvailable)
    if let action = globals.first(where: {
      $0.resolve { defaults.data(forKey: $0.prefsKey) } == hotKey
    }) {
      return "和全局快捷键「\(action.title)」重复"
    }
    return nil
  }
}
