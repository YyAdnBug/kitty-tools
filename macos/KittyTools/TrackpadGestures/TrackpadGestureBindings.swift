// 触控板手势插件绑了什么（issue #59 第 2 批，PLAN §10「触控板手势」）：三指 / 四指 / 五指 × 轻点 / 双击 / 长按九种，加上四个角 ×
// 轻点 / 双击八种（2026-11-28），每种绑一个全局动作（快捷键页那些 HotKeyAction）或一条启动器命令（「命令和别名」里的，编号同命令的快捷键）。
// 存在一个偏好里（Prefs.trackpadGestureBindings，注册了默认值「四指轻点 → 剪贴板历史」，拍板 B5：跟着导出、同步走），一行一种：
// 「4.tap=action:clipboard」「3.hold=command:<命令编号>」「bottomLeft.doubleTap=action:screenshot」。认不出的行（更新版本加的手指数、
// 角落的长按、手势、目标）原样留着、写回去时排在后面（同 HotKeyBlock）；同一种写了两行只认第一行。另有系统自己的三指手势占没占着
// （只读系统的触控板设置，拍板 B6）。

import Foundation

/// 几根手指（或哪个角）× 哪一种
struct TrackpadGesture: Hashable {
  enum Kind: String, CaseIterable {
    case tap, doubleTap, hold

    var title: LocalizedStringResource {
      switch self {
      case .tap: "轻点"
      // 「双击」在别处是鼠标的 Double-click：显式 key 分开
      case .doubleTap:
        LocalizedStringResource(
          "trackpadGestures.doubleTap", defaultValue: "双击", comment: "触控板手势：手指连着轻点两下")
      case .hold: "长按"
      }
    }
  }

  /// 几根手指，或单指在哪个角。**nonisolated**：主线程上的 TapSequence（nonisolated）拿它当键
  nonisolated enum Source: Hashable, Sendable {
    case fingers(Int)
    case corner(FingerGesture.Corner)

    /// 偏好里一行的开头：「4」「bottomLeft」
    var key: String {
      switch self {
      case .fingers(let fingers): String(fingers)
      case .corner(let corner): corner.rawValue
      }
    }

    var isCorner: Bool {
      if case .corner = self { true } else { false }
    }

    /// 能做哪几种：角落不认长按
    var kinds: [Kind] {
      switch self {
      case .fingers: Kind.allCases
      case .corner: [.tap, .doubleTap]
      }
    }

    static let all: [Source] =
      FingerGesture.fingerCounts.map { .fingers($0) }
      + FingerGesture.Corner.allCases.map { .corner($0) }
  }

  let source: Source
  let kind: Kind

  /// 十七种，按设置页的先后（三指的轻点、双击、长按，四指的……，左上角的轻点、双击，右上角的……）
  static let all: [TrackpadGesture] = Source.all.flatMap { source in
    source.kinds.map { TrackpadGesture(source, $0) }
  }

  var key: String { "\(source.key).\(kind.rawValue)" }

  var fingers: Int? {
    guard case .fingers(let fingers) = source else { return nil }
    return fingers
  }

  init(_ source: Source, _ kind: Kind) {
    self.source = source
    self.kind = kind
  }

  init(fingers: Int, kind: Kind) { self.init(.fingers(fingers), kind) }

  init(corner: FingerGesture.Corner, kind: Kind) { self.init(.corner(corner), kind) }

  /// 偏好里一行等号前面那截；认不出的 nil
  init?(key: some StringProtocol) {
    guard let gesture = Self.all.first(where: { $0.key == key }) else { return nil }
    self = gesture
  }

  /// 设置页那一行的名字：手指的那几行在「三指」这些组里，只写哪一种；角落的写全
  var title: LocalizedStringResource {
    guard case .corner(let corner) = source else { return kind.title }
    return switch (corner, kind == .doubleTap) {
    case (.topLeft, false): "左上角轻点"
    case (.topLeft, true): "左上角双击"
    case (.topRight, false): "右上角轻点"
    case (.topRight, true): "右上角双击"
    case (.bottomLeft, false): "左下角轻点"
    case (.bottomLeft, true): "左下角双击"
    case (.bottomRight, false): "右下角轻点"
    case (.bottomRight, true): "右下角双击"
    }
  }
}

/// 一种手势做什么
enum TrackpadGestureTarget: Hashable {
  case action(HotKeyAction)
  /// 启动器命令的编号（LauncherCommands 的 id，同命令的快捷键）
  case command(String)

  /// 偏好里一行等号后面那截；认不出的 nil
  init?(stored: some StringProtocol) {
    if stored.hasPrefix("action:"), let action = HotKeyAction(rawValue: String(stored.dropFirst(7)))
    {
      self = .action(action)
    } else if stored.hasPrefix("command:"), stored.count > 8 {
      self = .command(String(stored.dropFirst(8)))
    } else {
      return nil
    }
  }

  var stored: String {
    switch self {
    case .action(let action): "action:" + action.rawValue
    case .command(let id): "command:" + id
    }
  }

  /// 此刻用得上：动作的功能开着，命令要启动器开着（命令自己能不能跑做的那一刻再看）。用不上的照样存着，只是不听、不做
  var isActive: Bool {
    switch self {
    case .action(let action): action.isActive
    case .command: Feature.launcher.isOn
    }
  }

  /// 前台 App 在快捷键页「在这些 App 里停用」里停了它（拍板 B7）：动作看那一条停没停它，命令只跟「全部」（同命令的快捷键）
  func isBlocked(by rule: HotKeyBlock.Rule?) -> Bool {
    guard let rule else { return false }
    return switch self {
    case .action(let action): rule.blocks(action)
    case .command: rule.blocksCommands
    }
  }
}

/// 偏好里那一段：认得的手势 → 目标，加上认不出、原样留着的行
struct TrackpadGestureBindings: Equatable {
  /// 注册的默认值（拍板 B5：添加插件时四指轻点已经是剪贴板历史）
  static let defaultText = "4.tap=action:clipboard"
  /// 最多读这么多行（文件、同步来的再多也不看）
  static let maxLines = 64

  private(set) var targets: [TrackpadGesture: TrackpadGestureTarget] = [:]
  /// 认不出的行（原样）
  private var unknown: [String] = []

  init(text: String) {
    var seen = Set<String>()
    for line in text.split(separator: "\n").prefix(Self.maxLines) {
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals]
      guard !key.isEmpty, seen.insert(String(key)).inserted else { continue }
      if let gesture = TrackpadGesture(key: key),
        let target = TrackpadGestureTarget(stored: line[line.index(after: equals)...])
      {
        targets[gesture] = target
      } else {
        unknown.append(String(line))
      }
    }
  }

  /// 写回偏好的样子：认得的按十七种的先后，认不出的照原来的先后排在后面
  var text: String {
    let known = TrackpadGesture.all.compactMap { gesture in
      targets[gesture].map { gesture.key + "=" + $0.stored }
    }
    return (known + unknown).joined(separator: "\n")
  }

  var isEmpty: Bool { targets.isEmpty }

  /// 改一种（nil = 没有设）：那一种原来写的认不出的行一起换掉
  subscript(gesture: TrackpadGesture) -> TrackpadGestureTarget? {
    get { targets[gesture] }
    set {
      unknown.removeAll { $0.hasPrefix(gesture.key + "=") }
      targets[gesture] = newValue
    }
  }

  /// 此刻用得上的那几种（isActive）
  var active: [TrackpadGesture] {
    TrackpadGesture.all.filter { targets[$0]?.isActive == true }
  }
}

/// 系统自己的三指手势占着（拍板 B6）：「查询与数据检测器」设成三指轻点、打开了三指拖移。只读系统的触控板设置
/// （内置触控板、妙控板两个域，同 TrackpadSystemGesture），**不写**；有一个域开着就算
struct TrackpadSystemConflicts: Equatable {
  /// 三指轻点 = 查询
  var lookUp = false
  /// 三指拖移
  var drag = false
  /// 轻点来点按：角上那一下常被系统当成点按（2026-11-28 真机探针：离边 1–2% 的轻点都被点了，压力和真按下去一样是 1.0），
  /// 这时手势让开，只有点在最边上的认得出
  var tapToClick = false

  static let lookUpKey = "TrackpadThreeFingerTapGesture"
  static let dragKey = "TrackpadThreeFingerDrag"
  static let tapToClickKey = "Clicking"

  /// 注入的几个域给单测（不读这台的设置）
  static func read(_ domains: [UserDefaults]) -> Self {
    Self(
      lookUp: domains.contains { $0.integer(forKey: lookUpKey) == 2 },
      drag: domains.contains { $0.bool(forKey: dragKey) },
      tapToClick: domains.contains { $0.bool(forKey: tapToClickKey) })
  }

  static func current() -> Self {
    read(TrackpadSystemGesture.domains.compactMap { UserDefaults(suiteName: $0) })
  }

  var any: Bool { lookUp || drag }
}
