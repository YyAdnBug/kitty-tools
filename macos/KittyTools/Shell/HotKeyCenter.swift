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
// 安全输入（issue #27）：别的 App 开着它时只带 ⌥ 的出字的键收不到（HotKey.yieldsToSecureInput），注册照样成功、什么都看不出来；
// 系统故意的，公开接口绕不过去（2026-11-20 实测）。主界面打开时看一眼（secureInputBlock），挡着就在底下写一行是哪个 App；
// 菜单栏图标的橙色小锁跟着 checkSecureInput 走（切换前台 App、按下 ⌥ 时看，挡着时 3 秒复查到没了为止）。
// 重新注册、停用都记一条日志（类别 hotkeys）。

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

  /// 只带 ⌥（或 ⌥⇧）的字母数字符号键——会打出字的那些：有进程开着安全输入（别的 App 在输密码）时，系统不把它交给全局热键，
  /// 按键原样打进前台 App（issue #27；macOS 27.0.1 实测，2026-11-16 和 11-20 两次，合成按键和真键盘一样：⌥J、⌥⇧J、⌥1、⌥/
  /// 不响应，独占注册也一样；⌃⌥J、⌘⌥J 照常，**不出字的键照常**——⌥空格、⌥↩、⌥⌫、⌥↓、⌥Home、⌥F19、F18；连按两下不走
  /// Carbon，也照常。安全输入一关马上恢复）。默认键除了 ⌥空格（启动器）全是这种
  var yieldsToSecureInput: Bool {
    modifiers & UInt32(cmdKey | controlKey) == 0 && modifiers & UInt32(optionKey) != 0
      && Self.specialKeys[Int(keyCode)] == nil && Self.functionKeys[Int(keyCode)] == nil
  }

  /// 录制框录到这种组合时那一行的提示（不拦）
  var secureInputHint: String? {
    yieldsToSecureInput
      ? String(localized: "别的 App 在输密码时这个组合会失效；要随时能用，加上 ⌃ 或 ⌘，或改成连按两下修饰键")
      : nil
  }

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

  /// 当前键盘布局下这个键打出的字符（中文输入法下用它背后的 ASCII 布局）。modifiers：同时按着的 Carbon 修饰键位
  /// （E9 查 ⌥ + 字母打出什么）；死键给的是它自己那个附加符号，不是字母
  static func character(for keyCode: UInt16, modifiers: UInt32 = 0) -> String? {
    currentLayout().flatMap { character(for: keyCode, modifiers: modifiers, in: $0) }
  }

  /// 当前键盘布局（中文输入法下是它背后的 ASCII 布局）的 uchr 数据
  private static func currentLayout() -> Data? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
  }

  /// 当前键盘布局写着的第一种语言（波兰语 Pro 是 pl；E9 拿它补系统语言）
  private static func currentLayoutLanguage() -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
    else { return nil }
    return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first
  }

  /// 给定布局（uchr 数据）下这个键打出的字符（单测按 id 取系统自带的布局来算，不切换系统布局）
  nonisolated static func character(for keyCode: UInt16, modifiers: UInt32 = 0, in data: Data)
    -> String?
  {
    data.withUnsafeBytes { buffer -> String? in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return nil
      }
      var deadKeys: UInt32 = 0
      var length = 0
      var characters = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), (modifiers >> 8) & 0xFF,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
      guard status == noErr, length > 0 else { return nil }
      return String(utf16CodeUnits: characters, count: length)
    }
  }

  /// 键名（App 快捷键把菜单里只给了键码的快捷键还原成符号时也查这两张，MenuShortcuts）
  nonisolated static let specialKeys: [Int: String] = [
    kVK_Space: String(localized: "空格", comment: "按键名：空格键（快捷键里显示成 ⌥空格）"), kVK_Return: "↩",
    kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    // 小键盘的 Enter / Clear 按布局取出来是控制字符（画不出来）
    kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
  ]

  nonisolated static let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
    kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]
}

extension HotKey {
  /// 主键盘上的 1–9，按顺序：面板里 ⌘1–9（不带 ⌘ 的 1–9）选第几项都按它认（启动器、翻译浮窗、剪贴板、快速记一条、
  /// 选状态，第五轮体检 H4：原来各写一份）
  static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]
  /// 小键盘的 1–9（选状态、状态屏的退出密码也认它）
  static let keypadDigitKeys = [
    kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
    kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
  ]

  /// 面板里的固定键（⌘ + 字母、标点，和钉图、长截图面板上不带 ⌘ 的单个字母）按「打出来的字」认（第五轮体检 E2）：给回美式键盘上
  /// 打这个字的键位，调用方照旧拿 kVK_ANSI_* 比。德语键盘 Z、Y 互换、法语 A/Q Z/W 互换：⌘Z 认的是印着 Z 的那个键，同系统菜单。
  /// 打出来的不是 ASCII 字母 / 标点（俄文、希腊文这类布局）就退回物理键位（照美式的位置认，同这些布局下按 ⌘ 时系统菜单的做法）。
  /// 主键盘那一排数字、小键盘照旧按键位（法语键盘不按 ⇧ 时那一排打出的是 &é"'(，⌘1–9 认位置）；方向键、回车、Esc、Tab、Delete
  /// 打出来的是控制字符、不在表里，也照旧按键位。字母不分大小写（⇧ 照旧看修饰键）；⌥ ⌃ 不改这里认的字。纯函数，配单测。
  /// 录制框录的键（全局快捷键、截图时能改的键）不走这里：存的是物理键位、显示时按布局翻成字，本来就对得上。
  /// characters 由 NSEvent.shortcutCharacters 给：按着 ⌘ 时取布局 ⌘ 那一层的字（Dvorak – QWERTY ⌘ 这类按 ⌘ 换成美式的布局），
  /// 不按 ⌘ 的单键取 charactersIgnoringModifiers（typedCharacters）。
  /// 「+」也认（北欧在美式 - 的位置、德西意在 ] 的位置，不按 ⇧ 就打出来）：当成 ⌘= 那个键（⌘+ 放大），调用方照旧 (=, ⌘ / ⌘⇧) 都认。
  /// ponytail: 别的要按 ⇧ 才打得出的标点（法语键盘的「.」）照旧按键位；要认再把 ⇧ 也一起换算
  nonisolated static func keyCode(_ keyCode: Int, typing characters: String?) -> Int {
    guard !positionalKeys.contains(keyCode), let typed = characters?.lowercased(),
      typed.count == 1, let character = typed.first, let mapped = usKeys[character]
    else { return keyCode }
    return mapped
  }

  /// 美式键盘不按 ⇧ 时每个字母、标点在哪个键上（加一个「+」，见上）
  nonisolated private static let usKeys: [Character: Int] = {
    let letters = [
      kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
      kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
      kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
      kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
    ]
    var map = Dictionary(uniqueKeysWithValues: zip("abcdefghijklmnopqrstuvwxyz", letters))
    let punctuation: [(Character, Int)] = [
      ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
      ("]", kVK_ANSI_RightBracket), (";", kVK_ANSI_Semicolon), ("'", kVK_ANSI_Quote),
      ("\\", kVK_ANSI_Backslash), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period),
      ("/", kVK_ANSI_Slash), ("`", kVK_ANSI_Grave), ("+", kVK_ANSI_Equal),
    ]
    for (character, code) in punctuation { map[character] = code }
    return map
  }()

  /// 认哪一层的字（纯函数，配单测）：按着 ⌘ 时用布局 ⌘ 那一层的（取不到退回不按修饰键的），不按 ⌘ 时用不按修饰键的
  nonisolated static func typedCharacters(command: Bool, commandLayer: String?, plain: String?)
    -> String?
  {
    command ? commandLayer ?? plain : plain
  }

  /// 照旧按键位认的：主键盘那一排数字和整个小键盘
  nonisolated private static let positionalKeys: Set<Int> = [
    kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
    kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
    kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
    kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply,
    kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter,
    kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
  ]
}

extension HotKey {
  /// 只带 ⌥（或 ⌥⇧）的字母键在当前键盘布局下打出、这台 Mac 的语言里又用得到的那个字母（第五轮体检 E9）：设成全局快捷键后，
  /// 这个字在别的 App 里就打不出来了（波兰语 Pro 布局的 ⌥A = ą；用美式布局的法语用户 ⌥C = ç，北欧用户 ⌥A ⌥O = å ø）。
  /// 不是这种组合、打出来的不是非 ASCII 的字母（⌥Space 的不换行空格、⌥D 的 ∂、死键）、同一个布局不按 ⌥ 也打得出它的（土耳其 Q
  /// 的 ç ö 有自己的键）、语言里用不到它的（中文、英文系统 ABC 布局的 ⌥C = ç）都是 nil。语言 = 系统的语言列表（读不到退回
  /// Locale.preferredLanguages）加上当前布局写着的第一种语言（英文系统 + 波兰语 Pro 也算波兰语）。
  /// 新装第一次启动时这样的默认键先不注册（HotKeyAction.seedNewInstall）；录制框录到时提示一句（不拦）。
  /// ponytail: 两样没管——加拿大法语 CSA 布局的 ⌥A = æ（法语用到 æ，会被误扣，自己设回来）；美式布局上 ⌥N 是打 ñ 的死键，
  /// 死键不算字母、⌥N（快速记一条）照旧注册，西班牙语用户要自己改键
  var swallowedLetter: Character? {
    guard modifiers & UInt32(cmdKey | controlKey) == 0, modifiers & UInt32(optionKey) != 0,
      Self.specialKeys[Int(keyCode)] == nil, Self.functionKeys[Int(keyCode)] == nil,
      let layout = Self.currentLayout()
    else { return nil }
    let languages = Self.languages(
      system: InterfaceLanguage.systemLanguages, preferred: Locale.preferredLanguages,
      layout: Self.currentLayoutLanguage())
    return Self.swallowedLetter(
      typed: Self.character(for: UInt16(keyCode), modifiers: modifiers, in: layout),
      plain: Self.plainCharacters(in: layout), languages: languages)
  }

  /// 拿哪些语言判断（纯函数）：系统的语言列表（读不到用 preferred），布局的语言只在系统语言里没有同一种语言时才补——英文系统 +
  /// 波兰语 Pro 补上 pl；瑞士德语布局写的是 de（字母里有 ß），系统是 de-CH（瑞士不用 ß），不补，免得 ⌥S 被当成吞 ß
  nonisolated static func languages(system: [String], preferred: [String], layout: String?)
    -> [String]
  {
    let base = system.isEmpty ? preferred : system
    guard let layout else { return base }
    let code = Locale.Language(identifier: layout).languageCode
    return base.contains { Locale.Language(identifier: $0).languageCode == code }
      ? base : base + [layout]
  }

  /// 这个布局不按修饰键、只按 ⇧ 时各个键打得出的字（小写）
  nonisolated static func plainCharacters(in layout: Data) -> Set<String> {
    var typed = Set<String>()
    for code in 0..<UInt16(128) {
      for modifiers in [0, UInt32(shiftKey)] {
        if let text = character(for: code, modifiers: modifiers, in: layout) {
          typed.insert(text.lowercased())
        }
      }
    }
    return typed
  }

  /// 纯函数：typed 是这个组合打出来的字，plain 是同一个布局不按 ⌥ 打得出的字（小写），languages 是这台 Mac 的语言（每种语言
  /// 用到的字母取系统的 exemplarCharacterSet）
  nonisolated static func swallowedLetter(typed: String?, plain: Set<String>, languages: [String])
    -> Character?
  {
    guard let typed, typed.count == 1, let letter = typed.first, letter.isLetter, !letter.isASCII,
      !plain.contains(typed.lowercased())
    else { return nil }
    let lower = typed.lowercased()
    let used = languages.contains { language in
      let set = NSLocale(localeIdentifier: language).object(forKey: .exemplarCharacterSet)
      guard let set = set as? CharacterSet else { return false }
      return lower.unicodeScalars.allSatisfy(set.contains)
    }
    return used ? letter : nil
  }

  /// 录制框录到会吞字母的组合时那一行的提示（E9，不拦）
  var swallowHint: String? {
    swallowedLetter.map {
      String(
        localized: "在现在的键盘布局下 \(display) 会打出「\(String($0))」，设成全局后别的 App 里就打不出这个字了")
    }
  }
}

extension NSEvent {
  /// 这一下按键在面板里当成哪个键（HotKey.keyCode(_:typing:)，第五轮体检 E2）。只对按键事件用
  var typedKeyCode: Int {
    HotKey.keyCode(Int(keyCode), typing: shortcutCharacters)
  }

  /// 认快捷键用的字：按着 ⌘ 时取布局 ⌘ 那一层打出的字（Dvorak – QWERTY ⌘ 按 ⌘ 时换成美式；法语、德语、瑞典的 ⌘ 层和不按
  /// 修饰键一样），不按 ⌘ 时取 charactersIgnoringModifiers（HotKey.typedCharacters）。只对按键事件用
  var shortcutCharacters: String? {
    let command = modifierFlags.contains(.command)
    return HotKey.typedCharacters(
      command: command,
      commandLayer: command
        ? characters(byApplyingModifiers: modifierFlags.intersection([.command, .shift])) : nil,
      plain: charactersIgnoringModifiers)
  }
}

/// 追加动作只能加在末尾：注册时用 allCases 的下标当热键 id
enum HotKeyAction: String, CaseIterable {
  case clipboard, selectionTranslate, inputTranslate, screenshotTranslate, launcher, screenshot,
    screenshotLastRegion, recognizeText, translateReplace, screenRecord, audioRecord, pinClipboard,
    statusScreen, noteCapture, noteNew, noteAll, launchpad, shotHistory, island, clothesline, home,
    reminderNew, keepAwake, appShortcuts, noteDeck, delayedScreenshot

  var title: String { String(localized: titleResource) }

  /// 能本地化的标题（key 是中文原文；启动器搜索拿它的中文原文和拼音匹配，英文界面也搜得到中文）
  var titleResource: LocalizedStringResource {
    switch self {
    case .clipboard: "剪贴板历史"
    case .selectionTranslate: "划词翻译"
    case .inputTranslate: "输入翻译"
    case .screenshotTranslate: "截图翻译"
    case .launcher: "启动器"
    // 同一个中文、英文不同（页名「截图」是 Screenshot）：显式 key 分开
    case .screenshot:
      LocalizedStringResource("action.screenshot", defaultValue: "截图", comment: "动作：框选截图")
    case .screenshotLastRegion: "截取上次区域"
    case .delayedScreenshot: "延时截图"
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
    case .noteDeck: "屏幕边缘的便签"
    case .launchpad: "启动台"
    case .island: "打开刘海岛"
    case .home: "打开主界面"
    case .reminderNew: "新建提醒"
    case .keepAwake: "保持唤醒"
    case .appShortcuts: "显示 App 快捷键"
    }
  }

  /// 菜单栏、启动器里的标题：recording 是这一项正在录（录屏 / 录音录着时叫「停止录屏」/「停止录音」，再按一次快捷键也是停止；
  /// 录音控制条待录时不算在录，仍叫「录音」，点它 / 再按一次是开始）。保持唤醒手动开着一段时也算（再按一次是停止）
  func title(recording: Bool) -> String { String(localized: titleResource(recording: recording)) }

  func titleResource(recording: Bool) -> LocalizedStringResource {
    guard recording else { return titleResource }
    return switch self {
    case .screenRecord: "停止录屏"
    case .audioRecord: "停止录音"
    case .keepAwake: "停止保持唤醒"
    default: titleResource
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
    guard self == .statusScreen else { return title }
    return statusEntersFirst ? String(localized: "进入排在最前面的状态") : String(localized: "选一个状态进入")
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
    // 屏幕边缘那叠（第四轮体检 X16）不设默认键：主入口是鼠标靠过去，键给键盘用户自己设
    case .noteDeck: nil
    // 启动台（第八族）不设默认键：触控板捏合是主入口（系统那项开着时设置页会提示关），快捷键到 设置 › 快捷键 里自己设（SPEC R8）
    case .launchpad: nil
    // 新建提醒（2026-11-04，提醒 D5）不设默认键：打开启动器、填好「提醒 」，要快捷键到 设置 › 快捷键 里自己设
    case .reminderNew: nil
    // 保持唤醒（第一个插件，2026-11-12 拍板 B2）不设默认键：按一下开（无限期）、再按一下停
    case .keepAwake: nil
    // 刘海岛（2026-10-26）：刘海屏点刘海就能打开，键给没有刘海的屏用，到 设置 › 快捷键 里自己设
    case .island: nil
    // 主界面（2026-10-29）：主入口是点菜单栏图标，键给把图标藏起来的人自己设
    case .home: nil
    // App 快捷键（2026-11-17 拍板 B4）：主入口是按住 ⌘，键给不喜欢长按的人自己设
    case .appShortcuts: nil
    // 延时截图（第五轮体检 N2）不设默认键：要的人到 设置 › 快捷键 里自己设
    case .delayedScreenshot: nil
    }
  }

  /// 没存过 → 默认组合（新装时替这台 Mac 空着的默认键除外，E9）；存了空数据 → 已清除（nil）
  var hotKey: HotKey? {
    get {
      resolve(withheld: Self.withheld()) { UserDefaults.standard.data(forKey: $0.prefsKey) }
    }
    nonmutating set { UserDefaults.standard.set(Self.stored(newValue), forKey: prefsKey) }
  }

  /// 偏好里的键（设置的导出 / 导入也读写它，SettingsArchive）
  var prefsKey: String { "hotkey." + rawValue }

  /// 新装第一次启动（第五轮体检 E9；时机、条件同 Feature.seedNewInstall：Prefs.registerDefaults 之前，没看过任何一版、引导也
  /// 没开过）：默认键在这台的键盘布局和语言下会吞掉一个要用的字母的（HotKey.swallowedLetter），记进 Prefs.hotkeysWithheld——
  /// 这台 Mac 上不取这个默认（没存过的当没设、不注册），快捷键页那一行橙字说明（withheldNote），要用自己设一个。
  /// **不写 `hotkey.<动作>`**：那是改过的键，会跟着导出 / 同步去别的 Mac 把对面的默认键清掉，导入、加入同步时又被抹掉。
  /// 自己设的、同步 / 导入来的键照样盖过它（存着的就用存着的）。升级上来的不碰。swallows 单测里换掉
  static func seedNewInstall(
    _ defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier,
    swallows: (HotKey) -> Bool = { $0.swallowedLetter != nil }
  ) {
    let persisted = domainName.flatMap(defaults.persistentDomain(forName:)) ?? [:]
    guard persisted[Prefs.lastSeenVersion] == nil, persisted[Prefs.onboardingScreen] == nil,
      persisted[Prefs.hotkeysWithheld] == nil
    else { return }
    let withheld = allCases.filter { action in
      persisted[action.prefsKey] == nil && action.defaultHotKey.map(swallows) == true
    }
    if !withheld.isEmpty { defaults.set(withheld.map(\.rawValue), forKey: Prefs.hotkeysWithheld) }
  }

  /// 这台 Mac 上替用户空着的默认键（E9，seedNewInstall 记的）
  static func withheld(in defaults: UserDefaults = .standard) -> Set<HotKeyAction> {
    Set(
      (defaults.stringArray(forKey: Prefs.hotkeysWithheld) ?? []).compactMap(Self.init(rawValue:)))
  }

  /// 快捷键页这一行的橙字（E9）：新装时替这台 Mac 空着、现在也还空着的，说为什么空着；换了布局、现在不吞字母了的给一句通用的
  var withheldNote: String? {
    guard hotKey == nil, Self.withheld().contains(self), let key = defaultHotKey else {
      return nil
    }
    guard let letter = key.swallowedLetter else { return Self.withheldNote }
    return Self.withheldNote(key, letter: letter)
  }

  /// 换了布局、现在不吞字母了的那一句
  static var withheldNote: String {
    String(localized: "新装时按当时的键盘布局没占用这个默认键；要用就在右边设一个")
  }

  static func withheldNote(_ key: HotKey, letter: Character) -> String {
    String(
      localized: "在现在的键盘布局下 \(key.display) 用来打「\(String(letter))」，所以默认没占用；要用就在右边设一个")
  }

  /// 偏好里存的数据：组合的 JSON；清除了 = 空数据
  static func stored(_ hotKey: HotKey?) -> Data {
    hotKey.flatMap { try? JSONEncoder().encode($0) } ?? Data()
  }

  /// stored：各动作存的数据（nil = 没存过）。没存过取默认，但默认键已被别的动作自己设走时让给它、这个当没设：
  /// 改了默认键（A15 输入翻译 ⌘⇧I → ⌥T）以后，早先把 ⌥T 手动给了别的动作的人不该被新默认顶掉（抢先注册会让那个动作
  /// 每次启动都注册失败）。只比别的动作存下的值，不递归取默认。withheld：这台 Mac 上替用户空着的默认键（E9），没存过也当没设
  func resolve(withheld: Set<HotKeyAction> = [], stored: (HotKeyAction) -> Data?) -> HotKey? {
    let decode = { (data: Data) in try? JSONDecoder().decode(HotKey.self, from: data) }
    if let data = stored(self) { return decode(data) }
    guard !withheld.contains(self), let fallback = defaultHotKey,
      !Self.allCases.contains(where: { $0 != self && stored($0).flatMap(decode) == fallback })
    else { return nil }
    return fallback
  }

  /// 快捷键页、菜单栏、启动器、引导的分组（N13 / N15：同名同序），只列开着的功能（Feature；macOS 15 上没有启动台）。
  /// 每次现算：功能随时能在设置里开关
  static var sections: [Section] {
    visibleSections(enabled: Feature.enabled)
  }

  /// 一节：title 是显示的字，key 是它在目录里的 key（「节标题和唯一那一项同名」按 key 比，不拿显示的字比）
  typealias Section = (title: String, key: String, actions: [HotKeyAction])

  /// 单测喂集合：关着的功能的动作去掉、空了的节去掉；两个功能合一节的（剪贴板与启动器、截图与录制）只剩一个功能时，
  /// 节标题换成它的名字
  static func visibleSections(enabled: Set<Feature>) -> [Section] {
    allSections.compactMap { section in
      let actions = section.actions.filter { $0.feature.map(enabled.contains) ?? true }
      guard let first = actions.first else { return nil }
      let shared = Set(section.actions.map(\.feature)).count > 1
      let alone = Set(actions.map(\.feature)).count == 1
      let title =
        shared && alone ? first.feature.map(\.page.titleResource) ?? section.title : section.title
      return (String(localized: title), title.key, actions)
    }
  }

  /// 归哪个功能（Feature）：就是它所在的那一节——截图翻译归翻译（截图关了它照样能用）、钉住剪贴板里的图归截图。
  /// nil = 不属于哪个功能、一直在（打开刘海岛：岛是全 App 的轻提示，关不掉；打开主界面：全部功能的入口）
  var feature: Feature? {
    switch self {
    case .clipboard: .clipboard
    case .launcher: .launcher
    case .selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate: .translate
    case .screenshot, .screenshotLastRegion, .delayedScreenshot, .recognizeText, .pinClipboard,
      .shotHistory, .clothesline:
      .screenshot
    case .screenRecord, .audioRecord: .record
    case .noteCapture, .noteNew, .noteAll, .noteDeck: .notes
    case .launchpad: .launchpad
    case .statusScreen: .statusScreen
    case .reminderNew: .reminders
    case .keepAwake: .keepAwake
    case .appShortcuts: .appShortcuts
    // 「打开刘海岛」2026-11-13 起归刘海岛插件（原来 nil、一直在）；岛上的提示不归它
    case .island: .island
    case .home: nil
    }
  }

  /// 这台系统上有没有这一项（启动台只在 macOS 26 起有）：没有的不注册、不参与查重
  var isAvailable: Bool { feature?.isAvailable ?? true }

  /// 现在用得上：系统有、功能也开着。关着的功能不注册热键（交还给系统和别的 App）、不出现在任何入口；
  /// 查重仍然算它（HotKeyRecorder：重新打开时不和别的动作抢同一个组合）
  var isActive: Bool { feature?.isOn ?? true }

  private static let allSections: [(title: LocalizedStringResource, actions: [HotKeyAction])] = [
    ("剪贴板与启动器", [.clipboard, .launcher]),
    ("翻译", [.selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate]),
    // 钉住剪贴板里的图排在最后：菜单栏、启动器里有钉图时紧接着是「隐藏 / 关闭全部钉图」（MenuExtra），钉图的几项挨在一起
    (
      "截图与录制",
      [
        .screenshot, .screenshotLastRegion, .delayedScreenshot, .recognizeText, .screenRecord,
        .audioRecord, .pinClipboard, .shotHistory, .clothesline,
      ]
    ),
    // 便签（PLAN §10「便签」F②）：菜单栏、启动器、快捷键页、速查表各一节，三项同名同序
    ("便签", [.noteCapture, .noteNew, .noteAll, .noteDeck]),
    // 提醒（2026-11-04）：菜单栏里这一节同状态屏，只有一项「提醒」带子菜单（AppDelegate.addReminderMenu）。
    // 便签、提醒、状态屏挨着（功能管理拍板 M3，和设置侧栏同序）
    ("提醒", [.reminderNew]),
    // 菜单栏里这一节不画节标题，只有一项「状态屏」带子菜单（每个状态一行，AppDelegate.buildStatusMenu）
    ("状态屏", [.statusScreen]),
    // 启动台（第八族，2026-10-18）：和便签分开一节，菜单栏、启动器、快捷键页、速查表里的名字和设置页同名；
    // 2026-11-04 起排在状态屏后面（和程序坞预览一组）
    ("启动台", [.launchpad]),
    // 插件排在功能后面（同设置侧栏）。保持唤醒：菜单栏里同提醒，只有一项带子菜单（AppDelegate.addKeepAwakeMenu）
    ("保持唤醒", [.keepAwake]),
    // App 快捷键（插件，2026-11-17）：排在启动台后面、刘海岛前面（同设置侧栏）
    ("App 快捷键", [.appShortcuts]),
    // 刘海岛（2026-10-26）：2026-11-13 起归刘海岛插件，没添加时不列
    ("刘海岛", [.island]),
    // 主界面（2026-10-29）：不属于哪个功能、一直在；菜单栏菜单里不列（菜单就是图标的另一半），主界面里也不列它自己
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
    // 自画的那套里没有计时器：用 SF 的（同屏幕边缘的便签）
    case .delayedScreenshot: "timer"
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
    // 屏幕边缘那一列（X16）：SF 的侧栏
    case .noteDeck: "sidebar.right"
    case .launchpad: "kitty.launchpad"
    case .island: "kitty.island"
    // 从菜单栏垂下来的那一块
    case .home: "kitty.home"
    case .reminderNew: SettingsPage.reminders.symbol
    case .keepAwake: SettingsPage.keepAwake.symbol
    case .appShortcuts: SettingsPage.appShortcuts.symbol
    }
  }

  /// 功能家族色（截图翻译算翻译，和菜单栏一致）
  var color: Color {
    switch self {
    case .clipboard: Style.Family.clipboard
    case .launcher: Style.Family.command
    case .selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate:
      Style.Family.translate
    case .screenshot, .screenshotLastRegion, .delayedScreenshot, .recognizeText, .screenRecord,
      .audioRecord, .pinClipboard, .shotHistory, .clothesline:
      Style.Family.screenshot
    case .statusScreen: Style.Family.statusScreen
    case .noteCapture, .noteNew, .noteAll, .noteDeck: Style.Family.notes
    case .launchpad: Style.Family.launchpad
    case .reminderNew: Style.Family.reminders
    case .keepAwake: Style.Family.keepAwake
    case .appShortcuts: Style.Family.keyboard
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
  /// 本 App 的普通窗口（设置窗、全部便签、截图历史）当 key 时也把 Esc 转给它（录音待录条，不是倒数）
  @ObservationIgnored private var escapeToWindows = false
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
  /// 菜单栏图标的橙色小锁（AppDelegate 接）：挡着快捷键的安全输入出现、换了持有者、没了时调（checkSecureInput）
  @ObservationIgnored var onSecureInputChange: (SecureInputBlock?) -> Void = { _ in }
  /// 上次交给 onSecureInputChange 的；排着的那次复查；按下 ⌥ 时看一眼的全局监听
  @ObservationIgnored private var secureBlock: SecureInputBlock?
  @ObservationIgnored private var secureCheck: Task<Void, Never>?
  @ObservationIgnored private var optionMonitor: Any?
  /// 前台 App 的 bundle id：开始看时取一次，之后跟着激活通知改（通知里带的那个，不在通知里再读 frontmostApplication）
  @ObservationIgnored private var frontID: String?

  func setHandler(for action: HotKeyAction, _ handler: @escaping () -> Void) {
    handlers[action] = handler
  }

  /// 按偏好重新注册全部热键
  func reload() {
    unregisterAll()
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
    watchOption()
    checkSecureInput()
    watchTrust(HotKeyAction.allCases.contains { $0.isActive && $0.hotKey?.doubleTap != nil })
    // 只记个数和错误码（命令的编号可能是用户的脚本名，不记）
    let actions = failures.map { "\($0.key.rawValue) \($0.value)" }
    let commands = commandFailures.values.map { "command \($0)" }
    let failed = (actions + commands).sorted().joined(separator: ", ")
    Log.hotkeys.notice(
      "重新注册：\(self.bindings.count) 个动作、\(self.commandBindings.count) 条命令，按 App 停用 \(self.blockedSomething)，没注册上 [\(failed, privacy: .public)]"
    )
  }

  /// 此刻挡着快捷键的安全输入（主界面底下那一行、菜单栏图标的小锁、菜单最上面那行）。holder / bundleID：开着它的 App
  /// （会话字典里记的是负责的那个 App，2026-11-16 实测只在开着时才有这一项）；取不到 nil
  struct SecureInputBlock: Equatable {
    var holder: String?
    var bundleID: String? = nil

    /// 此刻开着安全输入的那个 App（不管挡没挡着快捷键；片段展开的设置页也用）；没开 nil
    static func current() -> SecureInputBlock? {
      guard IsSecureEventInputEnabled() else { return nil }
      let session = CGSessionCopyCurrentDictionary() as? [String: Any]
      let app = ((session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value)
        .flatMap { NSRunningApplication(processIdentifier: $0) }
      return SecureInputBlock(holder: app?.localizedName, bundleID: app?.bundleIdentifier)
    }

    /// 「「Google Chrome」开着安全输入，⌥ 快捷键暂时不响应」
    var summary: String {
      holder.map { String(localized: "「\($0)」开着安全输入，⌥ 快捷键暂时不响应") }
        ?? String(localized: "有 App 开着安全输入，⌥ 快捷键暂时不响应")
    }

    /// 怎么让它关掉，按开着它的 App 给（一句，不带句号）
    var advice: String {
      switch Holder(bundleID: bundleID) {
      case .terminal: String(localized: "在「终端」菜单里关掉「安全键盘输入」")
      case .iTerm: String(localized: "在「iTerm2」菜单里关掉「Secure Keyboard Entry」")
      case .browser: String(localized: "点一下网页上别的输入框或切个标签页；还不行就退出浏览器再打开")
      case .onePassword: String(localized: "锁定 1Password 再解锁，或者更新到新版")
      case .loginWindow: String(localized: "多半是锁屏或登录时留下的：锁定屏幕再解锁，还不行就注销重新登录")
      case .other:
        holder.map { String(localized: "切回「\($0)」点一下别的输入框，或者退出它") }
          ?? String(localized: "离开正在输密码的输入框，或者退出开着它的 App")
      }
    }

    /// 主界面那一行、菜单栏图标的悬停说明：为什么、怎么关、哪些不受影响
    var explanation: String {
      String(
        localized:
          "输入密码时系统会打开安全输入，这时只带 ⌥ 的字母、数字、符号键收不到，按键会打进那个输入框。\(advice)。带 ⌘ 或 ⌃ 的快捷键、⌥空格、F 键和连按两下修饰键不受影响。"
      )
    }

    /// 常见的几种持有者（有自己的关法）：终端和 iTerm2 的「安全键盘输入」会一直开着；Chromium 系浏览器离开密码框后有时不关
    /// （issue #27 报告人那次就是 Chrome）；1Password 旧版本有同样的问题；loginwindow 是锁屏、登录输密码时留下的
    enum Holder: Equatable {
      case terminal, iTerm, browser, onePassword, loginWindow, other

      init(bundleID: String?) {
        let id = bundleID?.lowercased() ?? ""
        let browsers = [
          "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.",
          "com.vivaldi.vivaldi", "com.operasoftware.opera", "org.chromium.chromium",
          "com.apple.safari", "org.mozilla.firefox",
        ]
        self =
          switch id {
          case "com.apple.terminal": .terminal
          case "com.googlecode.iterm2": .iTerm
          case "com.apple.loginwindow": .loginWindow
          case _ where id.hasPrefix("com.1password.") || id.hasPrefix("com.agilebits.onepassword"):
            .onePassword
          case _ where browsers.contains(where: id.hasPrefix): .browser
          default: .other
          }
      }
    }
  }

  /// 有进程开着安全输入、生效的快捷键里又有只带 ⌥ 的出字的键（这时它们按了没反应）才有
  func secureInputBlock() -> SecureInputBlock? {
    guard
      bindings.values.contains(where: \.yieldsToSecureInput)
        || commandBindings.values.contains(where: \.yieldsToSecureInput)
    else { return nil }
    return .current()
  }

  /// 看一眼安全输入挡没挡着快捷键，和上次不一样就交给 onSecureInputChange（菜单栏图标的小锁）。挡着时 3 秒后再看一次，
  /// 直到没了——安全输入关掉没有通知，只能复查；不挡着时不排下一次，平时不轮询。delay：切换前台 App 时等半秒（从密码框
  /// 切走的那一刻安全输入可能还没关，马上看会让小锁闪一下）
  func checkSecureInput(after delay: Duration = .zero) {
    secureCheck?.cancel()
    secureCheck = Task { [weak self] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard !Task.isCancelled, let self else { return }
      let block = secureInputBlock()
      if block != secureBlock {
        secureBlock = block
        Log.hotkeys.notice(
          "安全输入挡着只带 ⌥ 的快捷键：\(block?.bundleID ?? (block == nil ? "没了" : "认不出"), privacy: .public)"
        )
        onSecureInputChange(block)
      }
      guard block != nil else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      checkSecureInput()
    }
  }

  /// 有只带 ⌥ 的出字的键注册着时，看着全局的修饰键变化：⌥ 按下的那一刻多半是要按快捷键，看一眼安全输入（安全输入开着时
  /// 修饰键的变化照样收得到，2026-11-20 实测）。要辅助功能授权，没有时监听收不到东西，只剩切换前台 App 那一处在看
  private func watchOption() {
    if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
    optionMonitor = nil
    guard
      bindings.values.contains(where: \.yieldsToSecureInput)
        || commandBindings.values.contains(where: \.yieldsToSecureInput)
    else { return }
    optionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      MainActor.assumeIsolated {
        guard event.modifierFlags.contains(.option),
          [kVK_Option, kVK_RightOption].contains(Int(event.keyCode))
        else { return }
        self?.checkSecureInput()
      }
    }
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

  /// 注销全部（录制快捷键、截图框选、状态屏期间，免得按到现有组合就触发）；停的那一方结束时 reload
  func suspend() {
    Log.hotkeys.notice("停用全部快捷键（录快捷键、框选或状态屏）")
    unregisterAll()
  }

  private func unregisterAll() {
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
    watchOption()
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
    checkSecureInput(after: .milliseconds(500))
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

  /// 从 since（开机以来的秒数，同事件的时刻）到 now 之间没按过键盘上的键、鼠标键（App 快捷键的按住 ⌘ 另算滚轮）
  static func quiet(
    since: TimeInterval, now: TimeInterval,
    types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
  ) -> Bool {
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
  /// 这一下交给它、不回调（escapePressed）。返回 false = 没注册上（记一条日志，只能用录屏快捷键或 HUD 的 ✕ 取消）。
  /// 录音待录条（第五轮体检 A3）也用它：toWindows = 本 App 的普通窗口（设置窗、全部便签、截图历史）当 key 时同样把 Esc
  /// 转给那扇窗口（倒数只有那几秒，设置窗在前台时 Esc 照旧取消倒数）
  @discardableResult
  func registerEscape(toWindows: Bool = false, _ handler: @escaping () -> Void) -> Bool {
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
    escapeToWindows = toWindows
    return true
  }

  /// 临时 Esc 这会儿有人挂着（录屏倒数、录音待录条、延时截图倒数；全 App 只有一个，后挂的会把先挂的顶掉）
  var holdsEscape: Bool { escapeRef != nil }

  func unregisterEscape() {
    if let escapeRef { UnregisterEventHotKey(escapeRef) }
    escapeRef = nil
    onEscape = nil
    escapeToWindows = false
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
    if status == needsAccessibility { return String(localized: "连按两下要「辅助功能」授权") }
    return switch Int(status) {
    case eventInternalErr where optionOnly, eventHotKeyInvalidErr where optionOnly:
      String(localized: "macOS 15.0 / 15.1 不支持只带 ⌥ 的组合，加上 ⌘ 或 ⌃ 再录一次")
    case eventHotKeyExistsErr: String(localized: "和本 App 的另一个快捷键重复，没有注册上")
    default: String(localized: "没有注册上（错误 \(status)），换一个组合试试")
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
  /// 才回调（取消倒数）。录音待录条挂的（toWindows）本 App 的普通窗口当 key 时也交给它
  private func escapePressed() {
    guard let window = NSApp.keyWindow, window is NSPanel || escapeToWindows,
      let escape = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
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
