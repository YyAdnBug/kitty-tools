// 读前台 App 菜单栏里的快捷键（App 快捷键插件，2026-11-17 拍板「全部按推荐」，PLAN §10「App 快捷键」）。
// 走辅助功能：AXMenuBar → 各级菜单的子项，每项一次 AXUIElementCopyMultipleAttributeValues 取种类、标题、子项和四个
// AXMenuItemCmd* 属性。读的时候只读、不点菜单（执行一项是 press）。先问系统键盘在哪个 App 上：别家不激活的面板（比如系统的聚焦搜索）拿着键盘时，
// 前台 App 还是底下那个，按住 ⌘ 是给那块面板的，不弹（2026-11-17 评审）。
// 2026-11-17 本机实测（macOS 27，macos/build/research/cheatsheet-plugin-2026-11-17/）：读整个菜单栏之后 4–40 ms、
// 第一次最多 0.3 s（Chrome）；访达 117、Xcode 221、VS Code 107 条，Electron / Tauri 的菜单照样读得到。
// 主线程外跑（@concurrent，mac-native §3 第 3 类 AX 读）：只收 pid、给出值类型的结果；整次有总时限，每次跨进程调用用
// 剩下的时间当超时（同 ElementFinder：各给固定超时的话，卡住的 App 会卡好几秒）。
// 还原快捷键（keys，纯函数配单测）：先看菜单字形 AXMenuItemCmdGlyph，再看字符 AXMenuItemCmdChar（U+F700 起是
// AppKit 功能键的私用区），都没有再看键码 AXMenuItemCmdVirtualKey；修饰键位 1 ⇧、2 ⌥、4 ⌃、8 不带 ⌘、
// 16 🌐（头文件里没有，实测访达「表情与符号」= 24）。
// 不信 AXEnabled、不信标题是不是现在的：App 不在前台时它们是上次打开菜单时的样子（实测访达 117 条里 84 条「灰着」）。

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 菜单里有快捷键的一项（启动器搜菜单项时也收没有快捷键的，keys 是空的，read 的 includesPlain）
nonisolated struct MenuShortcut: Sendable, Hashable, Identifiable {
  /// 顶层菜单（文件、编辑……）
  let menu: String
  /// 顶层菜单和这一项之间的子菜单（「排序方式」）
  let path: [String]
  let title: String
  /// 「⌘S」「🌐⌃F」；两段式的「⌘K ⌘S」中间一个空格；没有快捷键的是空的（只有 includesPlain 才收）
  let keys: String
  /// 怎么找回它：菜单栏第几个，再一级级是菜单里第几项（执行时按它重新找、标题对得上才按）
  let location: [Int]
  /// 标题末尾原来有「…」（读的时候去掉了，好搜、好按标题找回来）：面板里照菜单画回来，不然 Xcode 的「Run」和
  /// 「Run…」看着一样（2026-11-20 改版拍板 B3）
  var hasEllipsis = false

  var id: [Int] { location }

  /// 面板里显示的标题
  var displayTitle: String { hasEllipsis ? title + "…" : title }
}

/// 读一次的结果
nonisolated struct MenuReading: Sendable {
  var shortcuts: [MenuShortcut] = []
  /// false：到点没读完、或者 App 不答（没响应），列的是读到的那些
  var finished = true
  /// 连菜单栏都拿不到（App 答了、但没有菜单栏）
  var unreadable = false
  /// 键盘在别的 App 上（别家不激活的面板拿着键盘）：不弹
  var focusedElsewhere = false
}

nonisolated enum MenuShortcuts {
  /// 整次读的上限（拍板 F2）
  static let budget: Duration = .seconds(1)
  /// 子菜单最多往下几层；一个菜单最多看多少项（浏览器的书签、历史动不动上千项、都没有快捷键，别把一秒耗在它们上）
  private static let maxDepth = 3
  private static let maxItems = 300

  /// 每项一次取这七样（缺的那样给的是包着错误的 AXValue）
  private static let names = [
    kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXMenuItemCmdCharAttribute,
    kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdVirtualKeyAttribute,
    kAXMenuItemCmdGlyphAttribute,
  ]

  /// 读 pid 那个 App 菜单栏里所有带快捷键的项（苹果菜单不读：每个 App 都一样，拍板 C3）。checksFocus：先问键盘在不在
  /// 它身上（单测读不在前台的访达时关掉）。includesPlain：没有快捷键的项也收（启动器搜菜单项，第五轮体检 N3；
  /// App 快捷键的面板只要有快捷键的）
  @concurrent static func read(
    pid: pid_t, budget: Duration = budget, checksFocus: Bool = true, includesPlain: Bool = false
  ) async -> MenuReading {
    let clock = ContinuousClock()
    let deadline = clock.now + budget
    var reading = MenuReading()
    var seen = Set<String>()
    let names = Self.names as CFArray

    /// 下一次跨进程调用最多等到总时限（至少 10 ms）；过了总时限 false
    func budgeted(_ element: AXUIElement) -> Bool {
      let left = clock.now.duration(to: deadline)
      guard left > .zero, !Task.isCancelled else {
        reading.finished = false
        return false
      }
      let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
      AXUIElementSetMessagingTimeout(element, Float(max(seconds, 0.01)))
      return true
    }
    func children(of element: AXUIElement) -> [AXUIElement] {
      guard budgeted(element) else { return [] }
      var value: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        == .cannotComplete
      {
        reading.finished = false
      }
      return value as? [AXUIElement] ?? []
    }
    /// 一个菜单里的各项；有子菜单的往下走
    func walk(_ menu: AXUIElement, top: String, path: [String], location: [Int]) {
      for (index, item) in children(of: menu).prefix(maxItems).enumerated() {
        guard reading.finished, budgeted(item) else { return }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(item, names, [], &values) == .success,
          let list = values as? [AnyObject], list.count == 7,
          Self.value(list[0]) as? String == kAXMenuItemRole
        else { continue }
        let title = Self.value(list[1]) as? String ?? ""
        let here = location + [index]
        if let submenu = (Self.value(list[2]) as? [AXUIElement])?.first {
          if path.count < maxDepth { walk(submenu, top: top, path: path + [title], location: here) }
          continue
        }
        let found: (title: String, keys: String)? =
          keys(
            char: Self.value(list[3]) as? String,
            glyph: (Self.value(list[6]) as? NSNumber)?.intValue,
            virtualKey: (Self.value(list[5]) as? NSNumber)?.intValue,
            modifiers: (Self.value(list[4]) as? NSNumber)?.intValue
          ).map { (cleaned(title), $0) } ?? bracketed(title)
          ?? (includesPlain ? (cleaned(title), "") : nil)
        guard let found, !found.title.isEmpty else { continue }
        // ⌥ 替换项照列；同一处同名同组合的只留一条
        let key = ([top] + path + [found.title, found.keys]).joined(separator: "\u{1F}")
        guard seen.insert(key).inserted else { continue }
        reading.shortcuts.append(
          MenuShortcut(
            menu: top, path: path, title: found.title, keys: found.keys, location: here,
            hasEllipsis: endsWithEllipsis(title)))
      }
    }

    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    if checksFocus, budgeted(system),
      AXUIElementCopyAttributeValue(
        system, kAXFocusedApplicationAttribute as CFString, &focused) == .success,
      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
      // 上面认过类型再强转
      var focusedPID: pid_t = 0
      if AXUIElementGetPid(focused as! AXUIElement, &focusedPID) == .success, focusedPID != pid {
        reading.focusedElsewhere = true
        return reading
      }
    }
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    let status: AXError =
      budgeted(app)
      ? AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) : .failure
    guard status == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else {
      // 卡住的 App 第一下就把时间用完（cannotComplete）：算没响应，不说成没有菜单栏
      if status == .cannotComplete || clock.now >= deadline { reading.finished = false }
      reading.unreadable = reading.finished
      return reading
    }
    let tops = children(of: bar as! AXUIElement)  // 认过类型
    for (index, top) in tops.enumerated() where index > 0 {
      guard reading.finished, budgeted(top) else { break }
      var title: CFTypeRef?
      AXUIElementCopyAttributeValue(top, kAXTitleAttribute as CFString, &title)
      guard let menu = children(of: top).first else { continue }
      walk(menu, top: (title as? String) ?? "", path: [], location: [index])
    }
    return reading
  }

  /// 按的结果：按了 / 找不回那一项（菜单变了）/ App 没接（这一刻用不了）
  enum Pressed { case pressed, changed, refused }

  /// 按菜单里的一项（点一行、↩、留住时按它的组合；拍板 D3）：按 location 一级级找回去，标题对得上才按（读完之后菜单
  /// 变了就不按）。AXPress 和从菜单里选它一样：这一刻能不能用由 App 自己定，菜单栏那一栏会闪一下。主线程，找的那几下
  /// 整次 0.5 秒封顶（同读：每次调用用剩下的时间当超时）；按的那一下只等 0.1 秒：会弹确认框、打开面板的项（清倒废纸篓、
  /// 打开…），App 要等那个窗口关了才回话，没回话（cannotComplete）也算按了
  static func press(_ shortcut: MenuShortcut, pid: pid_t) -> Pressed {
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(500)
    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      let left = clock.now.duration(to: deadline)
      guard left > .zero else { return nil }
      let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
      AXUIElementSetMessagingTimeout(element, Float(max(seconds, 0.01)))
      var result: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success
        ? result : nil
    }
    func child(_ element: AXUIElement, _ index: Int) -> AXUIElement? {
      let list = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
      return list.indices.contains(index) ? list[index] : nil
    }
    guard let first = shortcut.location.first,
      let bar = value(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
      CFGetTypeID(bar) == AXUIElementGetTypeID(),
      var element = child(bar as! AXUIElement, first)  // 认过类型
    else { return .changed }
    for index in shortcut.location.dropFirst() {
      guard let menu = child(element, 0), let item = child(menu, index) else { return .changed }
      element = item
    }
    guard let title = value(element, kAXTitleAttribute) as? String,
      cleaned(title) == shortcut.title || bracketed(title)?.title == shortcut.title
    else { return .changed }
    AXUIElementSetMessagingTimeout(element, 0.1)
    switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
    case .success, .cannotComplete: return .pressed
    default: return .refused
    }
  }

  /// 缺的属性回来的是包着错误的 AXValue（先认过类型再强转）
  private static func value(_ object: AnyObject) -> AnyObject? {
    if CFGetTypeID(object) == AXValueGetTypeID(), AXValueGetType(object as! AXValue) == .axError {
      return nil
    }
    return object
  }

  // MARK: 还原快捷键（纯函数）

  /// 菜单项的四个属性 → 「⌃⌥⇧⌘S」；没有快捷键、还原不出的 nil
  static func keys(char: String?, glyph: Int?, virtualKey: Int?, modifiers: Int?) -> String? {
    let char = char ?? ""
    let glyph = glyph ?? 0
    let key: String? =
      if glyph != 0, let name = glyphs[glyph] {
        name
      } else if !char.isEmpty {
        name(of: char)
      } else if glyph == 0, let virtualKey {
        HotKey.specialKeys[virtualKey] ?? HotKey.functionKeys[virtualKey]
      } else {
        nil
      }
    guard let key else { return nil }
    let bits = modifiers ?? 0
    var result = ""
    if bits & 16 != 0 { result += "🌐" }
    if bits & 4 != 0 { result += "⌃" }
    if bits & 2 != 0 { result += "⌥" }
    if bits & 1 != 0 { result += "⇧" }
    if bits & 8 == 0 { result += "⌘" }
    return result + key
  }

  /// 字符的键名：字母大写；AppKit 功能键的私用区、几个控制字符换成符号；别的控制字符、私用区画不出来的 nil
  static func name(of char: String) -> String? {
    guard let scalar = char.unicodeScalars.first else { return nil }
    switch scalar.value {
    case 0xF700, 0x1E: return "↑"
    case 0xF701, 0x1F: return "↓"
    case 0xF702, 0x1C: return "←"
    case 0xF703, 0x1D: return "→"
    case 0xF704...0xF726: return "F\(scalar.value - 0xF704 + 1)"
    case 0xF728: return "⌦"
    case 0xF729: return "↖"
    case 0xF72B: return "↘"
    case 0xF72C: return "⇞"
    case 0xF72D: return "⇟"
    case 0x08, 0x7F: return "⌫"
    case 0x0D: return "↩"
    case 0x03: return "⌤"
    case 0x09: return "⇥"
    case 0x19: return "⇤"
    case 0x1B: return "⎋"
    case 0x20: return HotKey.specialKeys[kVK_Space]
    case 0...0x1F, 0xF700...0xF8FF: return nil
    default: return char.uppercased()
    }
  }

  /// Carbon 的菜单字形（HIToolbox Menus.h 的 kMenu…Glyph；0x96 是听写的麦克风，头文件里没有，实测访达「开始听写」）
  private static let glyphs: [Int: String] = {
    var table: [Int: String] = [
      0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x0A: "⌦", 0x0B: "↩", 0x0C: "↩", 0x0D: "↩",
      0x17: "⌫", 0x1B: "⎋", 0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→", 0x66: "↖",
      0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟", 0x8C: "⏏", 0x96: "🎤",
    ]
    table[0x09] = HotKey.specialKeys[kVK_Space]  // 「空格」，跟着界面语言（同快捷键页）
    for number in 1...12 { table[0x6E + number] = "F\(number)" }
    for number in 13...15 { table[0x87 + number - 13] = "F\(number)" }
    for number in 16...19 { table[0x8F + number - 16] = "F\(number)" }
    return table
  }()

  /// 标题末尾有「…」「...」（两段式写在方括号里的看方括号前面：「Foo… [⌘K ⌘S]」）
  static func endsWithEllipsis(_ title: String) -> Bool {
    var title = title.trimmingCharacters(in: .whitespaces)
    if bracketed(title) != nil, let open = title.lastIndex(of: "[") {
      title = title[..<open].trimmingCharacters(in: .whitespaces)
    }
    return title.hasSuffix("…") || title.hasSuffix("...")
  }

  /// 标题末尾的「…」「...」去掉（拍板 C3）
  static func cleaned(_ title: String) -> String {
    var title = title.trimmingCharacters(in: .whitespaces)
    for suffix in ["…", "..."] where title.hasSuffix(suffix) {
      title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
    }
    return title
  }

  /// 菜单表达不了的两段式快捷键，有的 App 写进标题末尾的方括号（VS Code「Keyboard Shortcuts [⌘K ⌘S]」）：
  /// 方括号里带 ⌘ / ⌃ / ⌥ 才算
  static func bracketed(_ title: String) -> (title: String, keys: String)? {
    guard title.hasSuffix("]"), let open = title.lastIndex(of: "[") else { return nil }
    let keys = title[title.index(after: open)..<title.index(before: title.endIndex)]
      .trimmingCharacters(in: .whitespaces)
    guard keys.contains(where: { "⌘⌃⌥".contains($0) }) else { return nil }
    let name = cleaned(String(title[..<open]))
    return name.isEmpty ? nil : (name, keys)
  }
}
