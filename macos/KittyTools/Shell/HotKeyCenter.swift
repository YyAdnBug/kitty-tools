// 全局热键（Carbon RegisterEventHotKey，唯一能「按下即消费」的公开 API）。
// 每个动作的组合存在 UserDefaults；清除后为 nil、不注册。默认非独占注册：别的 App 注册了同一组合也会成功，
// 按一次两边都响应，且检测不到这种跨进程冲突（M1 实测，见 mac-overlay-panel 技能）。
// 另外给界面用：动作的分组 / 色块（快捷键页、速查表、引导、菜单栏共用）、注册失败的原因、最近一次触发（引导「按一下试试」）。
// 本 App 自己的菜单开着时热键事件会压在队列里、关了才派发，所以看到热键就先关菜单（watch(_:)）。
// 录屏倒数期间临时注册一个不带修饰键的 Esc（registerEscape，录制 HUD 不当 key、收不到按键；和各动作的热键分开记）。
// 启动器「命令和别名」里每条命令的快捷键（脚本命令第三轮 D1）也在这里注册：哪些由 commandHotKeys 给（AppDelegate 只给此刻
// 能做事的），按下交给 onCommand；热键 id 从 commandBase 起，每条命令这次运行里一个固定的号（不按排在第几：重新注册后，
// 按旧号排着队的事件不能落到别的命令上），和动作的下标、临时 Esc 不撞；注册失败的原因记在 commandFailures。
// 连按两下修饰键（2026-11-06 拍板 B）不走 Carbon：全局 + 本地监听修饰键变化，交给 ModifierTaps 认，只听不拦；
// 要「辅助功能」授权（没有时那一行写橙字 + 去授权，别的快捷键照常），授权变了跟着重来。
// 按 App 停用（2026-11-10，HotKeyBlock）：名单里的 App 在前台时 reload 不注册它停用的那几个（「全部」时连命令的快捷键、
// 连按两下一起），按键原样到那个 App；看着前台切换（frontChanged），停用的集合变了才重新注册一遍（8 个热键约 0.3 ms）。
// 录屏倒数的临时 Esc 不受名单管。本 App 的浮层不激活自己，开在名单里的 App 上面时前台还是它、快捷键照样停着。

import AppKit
import Carbon.HIToolbox
import OSLog
import Observation
import SwiftUI

struct HotKey: Codable, Hashable {
  /// 虚拟键码（kVK_*，按物理键位）
  var keyCode: UInt32
  /// Carbon 修饰键位：cmdKey / shiftKey / optionKey / controlKey
  var modifiers: UInt32

  /// 录制时从按键事件构造；没有 ⌘ / ⌃ / ⌥ 的组合（F1–F20 除外）不能当全局热键，会吞掉正常输入
  init?(event: NSEvent) {
    let key = HotKey(keyCode: event.keyCode, flags: event.modifierFlags)
    guard key.hasGlobalModifier else { return nil }
    self = key
  }

  /// 连按两下这个修饰键（拍板 B）：键位是修饰键自己的（左边那个）、不带修饰键位。0.7.2 及之前的版本读到它是一个
  /// 「没有修饰键的修饰键」，isUsable 不认，导入、同步都会丢掉；注册了也永远按不出来
  init(doubleTap key: ModifierTaps.Key) {
    self.init(keyCode: key.keyCode, modifiers: 0)
  }

  /// 是连按两下哪个修饰键（不是返回 nil）
  var doubleTap: ModifierTaps.Key? {
    guard modifiers == 0 else { return nil }
    return ModifierTaps.Key.allCases.first { $0.keyCode == Int(keyCode) }
  }

  /// 带 ⌘ / ⌃ / ⌥，或者是 F1–F20：能当全局热键的最低要求（录制框、导入设置同一条）
  var hasGlobalModifier: Bool {
    modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
      || Self.functionKeys.keys.contains(Int(keyCode))
  }

  /// 文件里读进来的组合能不能用（导入设置，SettingsArchive）：键码、修饰键位都在范围里，录制框会拒绝的这里也拒绝
  var isUsable: Bool {
    keyCode < 128 && modifiers & ~UInt32(cmdKey | shiftKey | optionKey | controlKey) == 0
      && (doubleTap != nil || (hasGlobalModifier && !isReservedEditKey))
  }

  /// 算不算一次「快捷键」（录屏「只显示快捷键」，InputOverlay）：带 ⌘ / ⌃ / ⌥ 的组合，或者不带它们的 F 键、Esc——这两样
  /// 不出字、是一步操作，观众从画面上看不出按了什么。字母数字符号、空格、⇧ 加它们是打字；↩ ⇥ ⌫ 方向键是打字时的编辑和移动
  /// （结果在画面上看得到，按得又多），都不算
  var isShortcut: Bool {
    modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
      || Self.functionKeys.keys.contains(Int(keyCode)) || Int(keyCode) == kVK_Escape
  }

  /// 按键事件的键位和修饰键原样记下（不管能不能当全局热键）：录屏的按键提示拿它的 display 当键名（InputOverlay），
  /// 和快捷键页、菜单同一套写法，不另写一份映射
  init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
    let flags = flags.intersection(.deviceIndependentFlagsMask)
    var modifiers = 0
    if flags.contains(.command) { modifiers |= cmdKey }
    if flags.contains(.option) { modifiers |= optionKey }
    if flags.contains(.control) { modifiers |= controlKey }
    if flags.contains(.shift) { modifiers |= shiftKey }
    self.init(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
  }

  init(keyCode: Int, modifiers: Int) {
    self.keyCode = UInt32(keyCode)
    self.modifiers = UInt32(modifiers)
  }

  init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// 各 App 通用的编辑 / 窗口快捷键（⌘Q ⌘W ⌘A ⌘S ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘H ⌘M ⌘`）：注册成全局热键后所有 App 里都收不到，
  /// 录制时直接拒绝。系统自己拦截的（⌘⇧4、⌘Space 等）根本录不进来，不用列
  static let reservedEditKeys: Set<HotKey> = Set(
    [
      (kVK_ANSI_Q, cmdKey), (kVK_ANSI_W, cmdKey), (kVK_ANSI_A, cmdKey), (kVK_ANSI_S, cmdKey),
      (kVK_ANSI_Z, cmdKey), (kVK_ANSI_Z, cmdKey | shiftKey), (kVK_ANSI_X, cmdKey),
      (kVK_ANSI_C, cmdKey), (kVK_ANSI_V, cmdKey), (kVK_ANSI_H, cmdKey), (kVK_ANSI_M, cmdKey),
      (kVK_ANSI_Grave, cmdKey),
    ].map { HotKey(keyCode: $0.0, modifiers: $0.1) })

  var isReservedEditKey: Bool { Self.reservedEditKeys.contains(self) }

  /// 例如 ⌘⇧V；连按两下是两个同样的修饰键「⌘⌘」（KeyCombo 画成两个键帽）
  var display: String {
    if let doubleTap { return doubleTap.symbol + doubleTap.symbol }
    let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
    return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyName
  }

  /// 菜单里显示用；按当前键盘布局取字符，取不到返回 nil
  var keyEquivalent: KeyEquivalent? {
    if doubleTap != nil { return nil }  // 系统菜单画不出连按
    if Int(keyCode) == kVK_Space { return .space }
    guard keyName.count == 1, let character = keyName.lowercased().first else { return nil }
    return KeyEquivalent(character)
  }

  var eventModifiers: SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
    if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
    if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
    if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
    return result
  }

  private var keyName: String {
    if let name = Self.specialKeys[Int(keyCode)] ?? Self.functionKeys[Int(keyCode)] { return name }
    return Self.character(for: UInt16(keyCode))?.uppercased() ?? "#\(keyCode)"
  }

  /// 当前键盘布局下这个键打出的字符（中文输入法下用它背后的 ASCII 布局）
  private static func character(for keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    return data.withUnsafeBytes { buffer -> String? in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return nil
      }
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length)
    }
  }

  private static let specialKeys: [Int: String] = [
    kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    // 小键盘的 Enter / Clear 按布局取出来是控制字符（画不出来）
    kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
  ]

  private static let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
    kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]
}

/// 追加动作只能加在末尾：注册时用 allCases 的下标当热键 id
enum HotKeyAction: String, CaseIterable {
  case clipboard, selectionTranslate, inputTranslate, screenshotTranslate, launcher, screenshot,
    screenshotLastRegion, recognizeText, translateReplace, screenRecord, audioRecord, pinClipboard,
    statusScreen, noteCapture, noteNew, noteAll, launchpad, shotHistory, island, clothesline, home,
    reminderNew

  var title: String {
    switch self {
    case .clipboard: "剪贴板历史"
    case .selectionTranslate: "划词翻译"
    case .inputTranslate: "输入翻译"
    case .screenshotTranslate: "截图翻译"
    case .launcher: "启动器"
    case .screenshot: "截图"
    case .screenshotLastRegion: "截取上次区域"
    case .recognizeText: "识字"
    case .translateReplace: "划词翻译并替换"
    case .screenRecord: "录屏"
    case .audioRecord: "录音"
    case .pinClipboard: "钉住剪贴板内容"
    case .shotHistory: "截图历史"
    case .clothesline: "晾衣绳"
    case .statusScreen: "状态屏"
    case .noteCapture: "快速记一条"
    case .noteNew: "新建便签"
    case .noteAll: "全部便签"
    case .launchpad: "启动台"
    case .island: "打开刘海岛"
    case .home: "打开主界面"
    case .reminderNew: "新建提醒"
    }
  }

  /// 菜单栏、启动器里的标题：recording 是这一项正在录（录屏 / 录音录着时叫「停止录屏」/「停止录音」，再按一次快捷键也是停止；
  /// 录音控制条待录时不算在录，仍叫「录音」，点它 / 再按一次是开始）
  func title(recording: Bool) -> String {
    guard recording else { return title }
    return switch self {
    case .screenRecord: "停止录屏"
    case .audioRecord: "停止录音"
    default: title
    }
  }

  /// 快捷键页、速查表里这一行的名字：状态屏的键照它实际做的事写（rowTitle(statusEntersFirst:)），别的同 title
  var rowTitle: String {
    rowTitle(
      statusEntersFirst: UserDefaults.standard.bool(forKey: Prefs.statusScreenHotKeyEntersFirst))
  }

  /// 状态屏的键默认是先出一排预览卡片、选一个再进（Z13a）；设置 › 状态屏打开「按快捷键直接进入排在最前面的状态」时
  /// 进的是列表里的第一个（Z10）
  func rowTitle(statusEntersFirst: Bool) -> String {
    self == .statusScreen ? (statusEntersFirst ? "进入排在最前面的状态" : "选一个状态进入") : title
  }

  /// nil = 默认不设键（静默替换这类用得少、又容易误触的）
  var defaultHotKey: HotKey? {
    switch self {
    // C = Clipboard，和 ⌥D / ⌥S / ⌥Space / ⌥A 同一组单 ⌥ 键。
    // 15.0–15.1 上只带 ⌥ 的组合注册不了，快捷键页会提示（下面的 ⌥ 键同样）
    case .clipboard: HotKey(keyCode: kVK_ANSI_C, modifiers: optionKey)
    // Bob 的划词翻译默认键；⌘⇧T 会占浏览器的「重新打开关闭的标签页」
    case .selectionTranslate: HotKey(keyCode: kVK_ANSI_D, modifiers: optionKey)
    // Bob 的输入翻译用 ⌥A（这里给了截图），取 ⌥T（T = Translate），和其它功能一样是单 ⌥ 键（体检 A15，2026-09-28）；
    // 只影响没改过这个键的人（hotKey 没存过才取默认）
    case .inputTranslate: HotKey(keyCode: kVK_ANSI_T, modifiers: optionKey)
    // Bob 的截图翻译默认键；不占各 App 的 ⌘⇧S「另存为」
    case .screenshotTranslate: HotKey(keyCode: kVK_ANSI_S, modifiers: optionKey)
    // Alfred 的默认键
    case .launcher: HotKey(keyCode: kVK_Space, modifiers: optionKey)
    // iShot 的框选截图默认键
    case .screenshot: HotKey(keyCode: kVK_ANSI_A, modifiers: optionKey)
    // iShot 的默认键，可以连按
    case .screenshotLastRegion: HotKey(keyCode: kVK_ANSI_X, modifiers: optionKey)
    // iShot 的默认键（O = OCR）
    case .recognizeText: HotKey(keyCode: kVK_ANSI_O, modifiers: optionKey)
    // 选中文字直接换成译文，不弹窗（Bob 的静默划词翻译也不设默认键）
    case .translateReplace: nil
    // R = Record，和截图框选里将来（第 2 批）按 R 转录屏对上
    case .screenRecord: HotKey(keyCode: kVK_ANSI_R, modifiers: optionKey)
    // 录音不设默认键（录音第 5 批：从菜单栏、启动器进，要快捷键到 设置 › 快捷键 里自己设）
    case .audioRecord: nil
    // 同上（第二轮体检 F1）
    case .pinClipboard: nil
    // 截图历史（2026-10-26 拍板 C2）：不占默认键，要的人自己设
    case .shotHistory: nil
    // 晾衣绳（第十族，2026-10-26 拍板 C1）：主入口是鼠标停到菜单栏那一条上，键给要的人自己设
    case .clothesline: nil
    // 状态屏（Z10）不设默认键：不能让人误触。设了键是先出选状态的面板（Z13a；设置里可改成直接进入列表里的第一个状态）
    case .statusScreen: nil
    // N = Note，和别的默认键一样是单 ⌥（便签拍板 F①：只有「快速记一条」有默认键）
    case .noteCapture: HotKey(keyCode: kVK_ANSI_N, modifiers: optionKey)
    // 新建便签、全部便签不设默认键：从菜单栏、启动器进，要快捷键到 设置 › 快捷键 里自己设
    case .noteNew, .noteAll: nil
    // 启动台（第八族）不设默认键：触控板捏合是主入口（系统那项开着时设置页会提示关），快捷键到 设置 › 快捷键 里自己设（SPEC R8）
    case .launchpad: nil
    // 新建提醒（2026-11-04，提醒 D5）不设默认键：打开启动器、填好「提醒 」，要快捷键到 设置 › 快捷键 里自己设
    case .reminderNew: nil
    // 刘海岛（2026-10-26）：刘海屏点刘海就能打开，键给没有刘海的屏用，到 设置 › 快捷键 里自己设
    case .island: nil
    // 主界面（2026-10-29）：主入口是点菜单栏图标，键给把图标藏起来的人自己设
    case .home: nil
    }
  }

  /// 没存过 → 默认组合；存了空数据 → 已清除（nil）
  var hotKey: HotKey? {
    get { resolve { UserDefaults.standard.data(forKey: $0.prefsKey) } }
    nonmutating set { UserDefaults.standard.set(Self.stored(newValue), forKey: prefsKey) }
  }

  /// 偏好里的键（设置的导出 / 导入也读写它，SettingsArchive）
  var prefsKey: String { "hotkey." + rawValue }

  /// 偏好里存的数据：组合的 JSON；清除了 = 空数据
  static func stored(_ hotKey: HotKey?) -> Data {
    hotKey.flatMap { try? JSONEncoder().encode($0) } ?? Data()
  }

  /// stored：各动作存的数据（nil = 没存过）。没存过取默认，但默认键已被别的动作自己设走时让给它、这个当没设：
  /// 改了默认键（A15 输入翻译 ⌘⇧I → ⌥T）以后，早先把 ⌥T 手动给了别的动作的人不该被新默认顶掉（抢先注册会让那个动作
  /// 每次启动都注册失败）。只比别的动作存下的值，不递归取默认
  func resolve(stored: (HotKeyAction) -> Data?) -> HotKey? {
    let decode = { (data: Data) in try? JSONDecoder().decode(HotKey.self, from: data) }
    if let data = stored(self) { return decode(data) }
    guard let fallback = defaultHotKey,
      !Self.allCases.contains(where: { $0 != self && stored($0).flatMap(decode) == fallback })
    else { return nil }
    return fallback
  }

  /// 快捷键页、菜单栏、启动器、引导的分组（N13 / N15：同名同序），只列开着的功能（Feature；macOS 15 上没有启动台）。
  /// 每次现算：功能随时能在设置里开关
  static var sections: [(title: String, actions: [HotKeyAction])] {
    visibleSections(enabled: Feature.enabled)
  }

  /// 单测喂集合：关着的功能的动作去掉、空了的节去掉；两个功能合一节的（剪贴板与启动器、截图与录制）只剩一个功能时，
  /// 节标题换成它的名字
  static func visibleSections(enabled: Set<Feature>) -> [(title: String, actions: [HotKeyAction])] {
    allSections.compactMap { section in
      let actions = section.actions.filter { $0.feature.map(enabled.contains) ?? true }
      guard let first = actions.first else { return nil }
      let shared = Set(section.actions.map(\.feature)).count > 1
      let alone = Set(actions.map(\.feature)).count == 1
      return (shared && alone ? first.feature?.title ?? section.title : section.title, actions)
    }
  }

  /// 归哪个功能（Feature）：就是它所在的那一节——截图翻译归翻译（截图关了它照样能用）、钉住剪贴板里的图归截图。
  /// nil = 不属于哪个功能、一直在（打开刘海岛：岛是全 App 的轻提示，关不掉；打开主界面：全部功能的入口）
  var feature: Feature? {
    switch self {
    case .clipboard: .clipboard
    case .launcher: .launcher
    case .selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate: .translate
    case .screenshot, .screenshotLastRegion, .recognizeText, .pinClipboard, .shotHistory,
      .clothesline:
      .screenshot
    case .screenRecord, .audioRecord: .record
    case .noteCapture, .noteNew, .noteAll: .notes
    case .launchpad: .launchpad
    case .statusScreen: .statusScreen
    case .reminderNew: .reminders
    case .island, .home: nil
    }
  }

  /// 这台系统上有没有这一项（启动台只在 macOS 26 起有）：没有的不注册、不参与查重
  var isAvailable: Bool { feature?.isAvailable ?? true }

  /// 现在用得上：系统有、功能也开着。关着的功能不注册热键（交还给系统和别的 App）、不出现在任何入口；
  /// 查重仍然算它（HotKeyRecorder：重新打开时不和别的动作抢同一个组合）
  var isActive: Bool { feature?.isOn ?? true }

  private static let allSections: [(title: String, actions: [HotKeyAction])] = [
    ("剪贴板与启动器", [.clipboard, .launcher]),
    ("翻译", [.selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate]),
    // 钉住剪贴板里的图排在最后：菜单栏、启动器里有钉图时紧接着是「隐藏 / 关闭全部钉图」（MenuExtra），钉图的几项挨在一起
    (
      "截图与录制",
      [
        .screenshot, .screenshotLastRegion, .recognizeText, .screenRecord, .audioRecord,
        .pinClipboard, .shotHistory, .clothesline,
      ]
    ),
    // 便签（PLAN §10「便签」F②）：菜单栏、启动器、快捷键页、速查表各一节，三项同名同序
    ("便签", [.noteCapture, .noteNew, .noteAll]),
    // 提醒（2026-11-04）：菜单栏里这一节同状态屏，只有一项「提醒」带子菜单（AppDelegate.addReminderMenu）。
    // 便签、提醒、状态屏挨着（功能管理拍板 M3，和设置侧栏同序）
    ("提醒", [.reminderNew]),
    // 菜单栏里这一节不画节标题，只有一项「状态屏」带子菜单（每个状态一行，AppDelegate.buildStatusMenu）
    ("状态屏", [.statusScreen]),
    // 启动台（第八族，2026-10-18）：和便签分开一节，菜单栏、启动器、快捷键页、速查表里的名字和设置页同名；
    // 2026-11-04 起排在状态屏后面（和程序坞预览一组）
    ("启动台", [.launchpad]),
    // 刘海岛（2026-10-26）：不属于哪个功能、一直在
    ("刘海岛", [.island]),
    // 主界面（2026-10-29）：同刘海岛，一直在；菜单栏菜单里不列（菜单就是图标的另一半），主界面里也不列它自己
    ("主界面", [.home]),
  ]

  /// 刘海岛那一张上的快捷动作（2026-10-26）：截图家族在前（同截图工具栏的顺序），再录制、快速记一条
  static let islandShortcuts: [HotKeyAction] = [
    .screenshot, .recognizeText, .screenshotTranslate, .screenRecord, .audioRecord, .noteCapture,
  ]

  /// 设置 › 刘海岛排的先后（Prefs.islandActionOrder，一行一个 rawValue）：不认识的、重复的丢掉，没排过的（以后新加的）
  /// 照 islandShortcuts 的先后补在最后。偏好是从导入、同步来的，不信它
  static func islandOrder(_ stored: String) -> [HotKeyAction] {
    var list: [HotKeyAction] = []
    for id in stored.split(separator: "\n") {
      if let action = HotKeyAction(rawValue: String(id)), islandShortcuts.contains(action),
        !list.contains(action)
      {
        list.append(action)
      }
    }
    return list + islandShortcuts.filter { !list.contains($0) }
  }

  /// 那一张上关掉的快捷动作（Prefs.islandActionsOff，一行一个 rawValue）
  static func islandOff(_ stored: String) -> Set<HotKeyAction> {
    Set(stored.split(separator: "\n").compactMap { HotKeyAction(rawValue: String($0)) })
      .intersection(islandShortcuts)
  }

  /// 种类色块里的符号：自画的功能图标（2026-10-30 拍板，mac 和 Windows 共用一套，见 SymbolImage）。
  /// 色块、菜单栏菜单、主界面、刘海岛、速查表都用它；截图工具栏、⌘K 里的同名按钮照旧是 SF Symbols（拍板 D2）
  var symbol: String {
    switch self {
    case .clipboard: "kitty.clipboard"
    case .launcher: "kitty.launcher"
    case .selectionTranslate: "kitty.translate.selection"
    case .inputTranslate: "kitty.translate.input"
    case .translateReplace: "kitty.translate.replace"
    // 截图家族三个共用取景框四角：截图、识字、截图翻译
    case .screenshotTranslate: "kitty.translate.screenshot"
    case .screenshot: "kitty.screenshot"
    case .screenshotLastRegion: "kitty.screenshot.last"
    case .recognizeText: "kitty.screenshot.text"
    case .screenRecord: "kitty.record"
    case .audioRecord: "kitty.record.audio"
    // 同速查表的「钉图」组；菜单里紧挨着的「隐藏全部钉图」是 SF 的 pin
    case .pinClipboard: "kitty.pin"
    case .shotHistory: "kitty.screenshot.history"
    case .clothesline: "kitty.clothesline"
    case .statusScreen: "kitty.status.screen"
    case .noteCapture: "kitty.notes.capture"
    case .noteNew: "kitty.notes.new"
    // 便签家族的符号（设置页头、速查表那一组也是它）
    case .noteAll: "kitty.notes"
    case .launchpad: "kitty.launchpad"
    case .island: "kitty.island"
    // 从菜单栏垂下来的那一块
    case .home: "kitty.home"
    case .reminderNew: SettingsPage.reminders.symbol
    }
  }

  /// 功能家族色（截图翻译算翻译，和菜单栏一致）
  var color: Color {
    switch self {
    case .clipboard: Style.Family.clipboard
    case .launcher: Style.Family.command
    case .selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate:
      Style.Family.translate
    case .screenshot, .screenshotLastRegion, .recognizeText, .screenRecord, .audioRecord,
      .pinClipboard, .shotHistory, .clothesline:
      Style.Family.screenshot
    case .statusScreen: Style.Family.statusScreen
    case .noteCapture, .noteNew, .noteAll: Style.Family.notes
    case .launchpad: Style.Family.launchpad
    case .reminderNew: Style.Family.reminders
    case .island, .home: Style.Family.general
    }
  }
}

@Observable final class HotKeyCenter {
  /// 当前生效的组合（菜单显示用）
  private(set) var bindings: [HotKeyAction: HotKey] = [:]
  /// 注册失败的动作及 OSStatus（-9868：15.0/15.1 上只带 ⌥ 的组合；-9878：本进程重复）。
  /// 只由 reload / suspend 写；不是 private(set) 只为截图自检直接摆出失败态（自检不能真注册热键，会吞用户的按键）
  var failures: [HotKeyAction: OSStatus] = [:]
  /// 最近一次触发的动作和累计触发次数（引导「按一下试试」看次数变化打勾：同一个键再按一次也要算）
  private(set) var lastFired: HotKeyAction?
  private(set) var fireCount = 0
  /// 正在录制的那一个（设置 › 快捷键：全局动作或截图时的键）：同一时刻只录一个，点了别的录制框，前一个就停下
  var recording: KeyTarget?
  /// 按偏好重新注册过几次：同步、导入改了快捷键后都会 reload，开着的录制框据此重读自己的组合（第四轮体检 E19）
  private(set) var generation = 0
  @ObservationIgnored private var handlers: [HotKeyAction: () -> Void] = [:]
  @ObservationIgnored private var refs: [EventHotKeyRef] = []
  @ObservationIgnored private var handlerRef: EventHandlerRef?
  /// 菜单跟踪通知的接收者（selector 形式，见 MenuTracking）
  @ObservationIgnored private var menuTracking: MenuTracking?
  @ObservationIgnored private var menuWatch: CFRunLoopTimer?
  /// 录屏倒数期间临时注册的 Esc（不带修饰键）和它的回调；suspend / reload 不碰它
  @ObservationIgnored private var escapeRef: EventHotKeyRef?
  @ObservationIgnored private var onEscape: (() -> Void)?
  private static let signature: OSType = 0x4B54_5459  // 'KTTY'
  /// 临时 Esc 的热键 id：不和动作的下标（allCases）撞
  private static let escapeID: UInt32 = 0xE5C
  /// 命令的快捷键的热键 id 从这里起（第几条加上它）
  private static let commandBase: UInt32 = 0x1000
  /// 要注册的命令的快捷键（编号、组合；按编号排好）和按下时做什么
  @ObservationIgnored var commandHotKeys: () -> [(id: String, hotKey: HotKey)] = { [] }
  @ObservationIgnored var onCommand: (String) -> Void = { _ in }
  /// 这次要注册的（注册没注册上都算）、注册上的组合，没注册上的和原因（-9878：和本 App 别的快捷键重复）
  @ObservationIgnored private var commandAttempts: [(id: String, hotKey: HotKey)] = []
  private(set) var commandBindings: [String: HotKey] = [:]
  private(set) var commandFailures: [String: OSStatus] = [:]
  /// 每条命令的热键 id（这次运行里不变、不复用）和反查
  @ObservationIgnored private var commandNumbers: [String: UInt32] = [:]
  @ObservationIgnored private var commandsByNumber: [UInt32: String] = [:]
  /// 这条命令在这台 Mac 上有没有（录制框查重只算有的：同步来的、删掉的脚本留下的组合没有那一行，改不掉，不该挡别人）
  @ObservationIgnored var knowsCommand: (String) -> Bool = { _ in true }

  /// 有生效的热键（动作的或命令的，或者只是因为前台 App 在停用名单里才没注册）：截图框选、状态屏停热键前看它，结束时才重新注册
  var isActive: Bool { !bindings.isEmpty || !commandBindings.isEmpty || blockedSomething }
  /// 连按两下要辅助功能授权、还没有（failures 里的值，不是 Carbon 的错误码）
  static let needsAccessibility: OSStatus = 1
  /// 连按两下：哪个修饰键归哪个动作，和认连按的状态机、两个监听（全局：别的 App 在前台；本地：本 App 的面板拿着键盘）
  @ObservationIgnored private var tapActions: [ModifierTaps.Key: HotKeyAction] = [:]
  @ObservationIgnored private var taps = ModifierTaps()
  @ObservationIgnored private var tapMonitors: [Any] = []
  /// 设了连按时盯着辅助功能授权的变化（系统改授权列表时发的分布式通知）：给了就装上监听，收回了就写橙字
  @ObservationIgnored private var trustObserver: NSObjectProtocol?
  @ObservationIgnored private var trustedWhenLoaded = false
  /// 热键停着（录快捷键、截图框选、状态屏）：授权变了也先不重新注册，等停的那一方自己 reload
  @ObservationIgnored private var suspended = false
  /// 按 App 停用：上次 reload 时对前台 App 生效的规则（nil = 没停），和因为它没注册的（isActive 也算它们：
  /// 截图框选、状态屏结束时据此决定要不要 reload，不然在名单 App 里开的截图结束后热键就永远停着了）
  @ObservationIgnored private var appliedBlock: HotKeyBlock.Rule?
  @ObservationIgnored private var blockedSomething = false
  @ObservationIgnored private var frontObserver: NSObjectProtocol?
  /// 前台 App 的 bundle id：开始看时取一次，之后跟着激活通知改（通知里带的那个，不在通知里再读 frontmostApplication）
  @ObservationIgnored private var frontID: String?

  func setHandler(for action: HotKeyAction, _ handler: @escaping () -> Void) {
    handlers[action] = handler
  }

  /// 按偏好重新注册全部热键
  func reload() {
    suspend()
    suspended = false
    generation += 1
    installHandlerIfNeeded()
    let trusted = Permissions.isAccessibilityTrusted
    trustedWhenLoaded = trusted
    watchFront()
    let block = HotKeyBlock.rule(for: frontID, in: HotKeyBlock.stored)
    appliedBlock = block
    for (index, action) in HotKeyAction.allCases.enumerated() {
      guard action.isActive, let hotKey = action.hotKey else { continue }
      if block?.blocks(action) == true {
        blockedSomething = true
        continue
      }
      if let key = hotKey.doubleTap {
        if trusted {
          tapActions[key] = action
          bindings[action] = hotKey
        } else {
          failures[action] = Self.needsAccessibility
        }
        continue
      }
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        hotKey.keyCode, hotKey.modifiers,
        EventHotKeyID(signature: Self.signature, id: UInt32(index)), GetApplicationEventTarget(), 0,
        &ref)
      if status == noErr, let ref {
        refs.append(ref)
        bindings[action] = hotKey
      } else {
        failures[action] = status
      }
    }
    registerCommands(blocked: block?.blocksCommands == true)
    watchTaps()
    watchTrust(HotKeyAction.allCases.contains { $0.isActive && $0.hotKey?.doubleTap != nil })
  }

  /// 命令的快捷键（在各动作之后注册：和动作撞了的是命令这边失败）。blocked：前台 App 停用了全部快捷键，照样记下要注册的
  /// （reloadCommandsIfChanged 和它比），一个都不注册
  private func registerCommands(blocked: Bool) {
    commandAttempts = commandHotKeys()
    if blocked {
      blockedSomething = blockedSomething || !commandAttempts.isEmpty
      return
    }
    for (id, hotKey) in commandAttempts {
      let number =
        commandNumbers[id]
        ?? {
          let next = Self.commandBase + UInt32(commandNumbers.count)
          commandNumbers[id] = next
          commandsByNumber[next] = id
          return next
        }()
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: number),
        GetApplicationEventTarget(), 0, &ref)
      if status == noErr, let ref {
        refs.append(ref)
        commandBindings[id] = hotKey
      } else {
        commandFailures[id] = status
      }
    }
  }

  /// 要注册的命令变了（脚本加了 / 删了、命令开了 / 关了、功能开关）：重新注册一遍；没变、正在录、热键停着的不动
  func reloadCommandsIfChanged() {
    guard recording == nil, !suspended else { return }
    let wanted = commandHotKeys()
    // 和上次要注册的比（不只比注册上的：有一条没注册上时，不该每次都当变了）
    guard
      wanted.map(\.id) != commandAttempts.map(\.id)
        || wanted.map(\.hotKey) != commandAttempts.map(\.hotKey)
    else { return }
    reload()
  }

  /// 命令的快捷键没注册上的原因（「命令和别名」那一行下面的橙字）
  func failureMessage(forCommand id: String) -> String? {
    commandFailures[id].map {
      Self.failureMessage($0, hotKey: LauncherModel.savedCommandHotKeys()[id])
    }
  }

  /// 注销全部（录制快捷键期间，免得按到现有组合就触发）
  func suspend() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs = []
    suspended = true
    bindings = [:]
    failures = [:]
    tapActions = [:]
    commandAttempts = []
    commandBindings = [:]
    commandFailures = [:]
    appliedBlock = nil
    blockedSomething = false
    watchTaps()
  }

  /// 第一次 reload 时开始看前台切换（之后一直看着；只比较规则，开销可以忽略）
  private func watchFront() {
    guard frontObserver == nil else { return }
    frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    frontObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let id = app?.bundleIdentifier
      MainActor.assumeIsolated { self?.frontChanged(id) }
    }
  }

  /// 前台换了 App：对它生效的停用规则和上次注册时不一样才重新注册（大多数切换两边都是「不停」，什么都不做）。
  /// 热键停着（录快捷键、截图框选、状态屏）时不动，停的那一方结束时 reload 会按那时的前台算
  private func frontChanged(_ bundleID: String?) {
    frontID = bundleID
    guard !suspended, handlerRef != nil,
      HotKeyBlock.rule(for: bundleID, in: HotKeyBlock.stored) != appliedBlock
    else { return }
    reload()
  }

  /// 停用名单改了（设置页、菜单栏那一项）：对此刻的前台重新算一遍
  func blocksChanged() {
    guard recording == nil, frontObserver != nil else { return }
    frontChanged(frontID)
  }

  /// 设了连按两下（有授权）才挂两个监听，否则摘掉；换了一批就从头认
  private func watchTaps() {
    for monitor in tapMonitors { NSEvent.removeMonitor(monitor) }
    tapMonitors = []
    taps = ModifierTaps()
    guard !tapActions.isEmpty else { return }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      MainActor.assumeIsolated { self?.flagsChanged(event) }
      return event
    }
    tapMonitors = [global, local].compactMap { $0 }
  }

  /// 修饰键变了：连按成了，而且第一下按下以来没按过别的键、鼠标（B3 B5：⌘C、⌘ 点击这些都不算），就触发那个动作
  private func flagsChanged(_ event: NSEvent) {
    guard let tap = taps.handle(flags: event.modifierFlags, at: event.timestamp),
      let action = tapActions[tap.key],
      Self.quiet(since: tap.since, now: ProcessInfo.processInfo.systemUptime)
    else { return }
    fire(UInt32(HotKeyAction.allCases.firstIndex(of: action) ?? 0))
  }

  /// 从 since（开机以来的秒数，同事件的时刻）到 now 之间没按过键盘上的键、鼠标键
  private static func quiet(since: TimeInterval, now: TimeInterval) -> Bool {
    let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    let latest =
      types.map {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
      }.min() ?? .infinity
    return latest > now - since
  }

  /// 设了连按两下时盯着辅助功能授权：系统改授权列表时发一个分布式通知（不带是谁），等一下再读（立刻读可能还是旧的），
  /// 变了就重新注册一遍（录快捷键时热键停着，录完自己会重来）
  private func watchTrust(_ needed: Bool) {
    guard needed != (trustObserver != nil) else { return }
    if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
    trustObserver = nil
    guard needed else { return }
    trustObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard let self, !self.suspended,
          Permissions.isAccessibilityTrusted != self.trustedWhenLoaded
        else { return }
        self.reload()
      }
    }
  }

  /// 这一行是连按两下、缺辅助功能授权（快捷键页那一行给「去授权」）
  func needsAccessibility(_ action: HotKeyAction) -> Bool {
    failures[action] == Self.needsAccessibility
  }

  /// 录屏倒数期间临时抢一个不带修饰键的 Esc（mac-overlay-panel §4）：录制 HUD 永不当 key，按键到不了它。只在倒数那几秒
  /// 挂着，倒数结束 / 取消 / 开录立刻 unregisterEscape（挂着时别的 App 都收不到 Esc）。本 App 自己的面板拿着键盘时
  /// 这一下交给它、不回调（escapePressed）。返回 false = 没注册上（记一条日志，只能用录屏快捷键或 HUD 的 ✕ 取消）
  @discardableResult
  func registerEscape(_ handler: @escaping () -> Void) -> Bool {
    unregisterEscape()
    installHandlerIfNeeded()
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.escapeID),
      GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else {
      Log.record.error("倒数的 Esc 热键没注册上：\(status)")
      return false
    }
    escapeRef = ref
    onEscape = handler
    return true
  }

  func unregisterEscape() {
    if let escapeRef { UnregisterEventHotKey(escapeRef) }
    escapeRef = nil
    onEscape = nil
  }

  /// 注册失败的原因（快捷键页、引导里那一行下面的橙字）；注册成功或没设键时为 nil
  func failureMessage(for action: HotKeyAction) -> String? {
    failures[action].map { Self.failureMessage($0, hotKey: action.hotKey) }
  }

  static func failureMessage(_ status: OSStatus, hotKey: HotKey?) -> String {
    let modifiers = hotKey?.modifiers ?? 0
    let optionOnly =
      modifiers & UInt32(cmdKey | controlKey) == 0 && modifiers & UInt32(optionKey) != 0
    // 15.0–15.1 上只带 ⌥（或 ⌥⇧）的组合返回 -9868（eventInternalErr，M1 实测；以前按 eventHotKeyInvalidErr
    // -9879 判断，从来没对上过），两个都认，但只在组合确实只带 ⌥ 时才这么说
    if status == needsAccessibility { return "连按两下要「辅助功能」授权" }
    return switch Int(status) {
    case eventInternalErr where optionOnly, eventHotKeyInvalidErr where optionOnly:
      "macOS 15.0 / 15.1 不支持只带 ⌥ 的组合，加上 ⌘ 或 ⌃ 再录一次"
    case eventHotKeyExistsErr: "和本 App 的另一个快捷键重复，没有注册上"
    default: "没有注册上（错误 \(status)），换一个组合试试"
    }
  }

  private func fire(_ id: UInt32) {
    if id == Self.escapeID { return escapePressed() }
    if id >= Self.commandBase {
      // 只认此刻注册着的：注销了的号上排着队的事件不做
      if let command = commandsByNumber[id], commandBindings[command] != nil { onCommand(command) }
      return
    }
    guard Int(id) < HotKeyAction.allCases.count else { return }
    let action = HotKeyAction.allCases[Int(id)]
    lastFired = action
    fireCount += 1
    handlers[action]?()
  }

  /// 临时 Esc 按下：本 App 自己的面板拿着键盘（倒数中又开了截图框选、剪贴板、启动器、翻译浮窗，点了钉图……；录制 HUD
  /// 永不当 key，不会是它）时，这一下 Esc 是给那个面板的——Carbon 热键把按键整个吞了，合成一个 Esc 按下经 NSApp.sendEvent
  /// 照常派发（和真按键同一条路：本地监听、performKeyEquivalent、第一响应者），不回调；别的 App 或设置窗（NSWindow）在前台时
  /// 才回调（取消倒数）
  private func escapePressed() {
    guard let panel = NSApp.keyWindow as? NSPanel,
      let escape = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: UInt16(kVK_Escape))
    else {
      onEscape?()
      return
    }
    NSApp.sendEvent(escape)
  }

  /// 本 App 的菜单（菜单栏、右键、⋯、设置里的弹出菜单）跟踪期间，热键事件压在队列里，菜单关了才派发
  /// （同 KeyboardShortcuts #1、HotKey #17；实测按下后菜单一直开着，关掉那一刻才触发）。
  /// 跟踪期间一直看着 Carbon 主队列：有热键就先关菜单，压着的那个事件随后由主循环照常派发给
  /// fire()——只用它这一个，不会重复触发，也不用反注册、自己匹配键位。定时器 50 ms 看一次、只在菜单开着时跑
  /// （不指望热键唤醒跟踪中的 run loop）；关菜单不带淡出，带淡出浮层要多等约 0.25 s。实测按下到触发 15–65 ms，
  /// 见 HotKeyMenuTests
  fileprivate func watch(_ menu: NSMenu?) {
    if let menuWatch { CFRunLoopTimerInvalidate(menuWatch) }
    menuWatch = nil
    // 录快捷键、框选截图时热键停着，不用看
    guard let menu, !refs.isEmpty else { return }
    let timer = CFRunLoopTimerCreateWithHandler(
      nil, CFAbsoluteTimeGetCurrent() + 0.05, 0.05, 0, 0
    ) { timer in
      MainActor.assumeIsolated {
        var spec = EventTypeSpec(
          eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // 只看不取（会顺带从 WindowServer 拉新事件）：留在队列里，菜单关了由主循环派发
        guard
          let event = AcquireFirstMatchingEventInQueue(
            GetMainEventQueue(), 1, &spec, OptionBits(kEventQueueOptionsNone))
        else { return }
        ReleaseEvent(event)
        CFRunLoopTimerInvalidate(timer)
        menu.cancelTrackingWithoutAnimation()
      }
    }
    CFRunLoopAddTimer(
      CFRunLoopGetMain(), timer, CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
    menuWatch = timer
  }

  private func installHandlerIfNeeded() {
    guard handlerRef == nil else { return }
    let tracking = MenuTracking(center: self)
    let center = NotificationCenter.default
    center.addObserver(
      tracking, selector: #selector(MenuTracking.began(_:)),
      name: NSMenu.didBeginTrackingNotification, object: nil)
    center.addObserver(
      tracking, selector: #selector(MenuTracking.ended(_:)),
      name: NSMenu.didEndTrackingNotification, object: nil)
    menuTracking = tracking
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    // Carbon 事件在主线程投递
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard let userData else { return noErr }
        MainActor.assumeIsolated {
          Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(hotKeyID.id)
        }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
  }
}

/// 菜单开始 / 结束跟踪的通知接收者。菜单通知在主线程同步发出，@objc 方法按默认的 MainActor 隔离
/// （Swift 6 对 @objc 入口有运行时隔离检查兜底），所以不用在闭包里把 note.object 标成 nonisolated(unsafe)（mac-native §3）
private final class MenuTracking: NSObject {
  weak var center: HotKeyCenter?

  init(center: HotKeyCenter) { self.center = center }

  @objc func began(_ note: Notification) { center?.watch(note.object as? NSMenu) }
  @objc func ended(_ note: Notification) { center?.watch(nil) }
}
