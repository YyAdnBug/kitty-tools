// 全局热键（Carbon RegisterEventHotKey，唯一能「按下即消费」的公开 API）。
// 每个动作的组合存在 UserDefaults；清除后为 nil、不注册。默认非独占注册：别的 App 注册了同一组合也会成功，
// 按一次两边都响应，且检测不到这种跨进程冲突（M1 实测，见 mac-overlay-panel 技能）。
// 另外给界面用：动作的分组 / 色块（快捷键页、速查表、引导、菜单栏共用）、注册失败的原因、最近一次触发（引导「按一下试试」）。
// 本 App 自己的菜单开着时热键事件会压在队列里、关了才派发，所以看到热键就先关菜单（watch(_:)）。
// 录屏倒数期间临时注册一个不带修饰键的 Esc（registerEscape，录制 HUD 不当 key、收不到按键；和各动作的热键分开记）。

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

  /// 带 ⌘ / ⌃ / ⌥，或者是 F1–F20：能当全局热键的最低要求（录制框、导入设置同一条）
  var hasGlobalModifier: Bool {
    modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
      || Self.functionKeys.keys.contains(Int(keyCode))
  }

  /// 文件里读进来的组合能不能用（导入设置，SettingsArchive）：键码、修饰键位都在范围里，录制框会拒绝的这里也拒绝
  var isUsable: Bool {
    keyCode < 128 && modifiers & ~UInt32(cmdKey | shiftKey | optionKey | controlKey) == 0
      && hasGlobalModifier && !isReservedEditKey
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

  /// 例如 ⌘⇧V
  var display: String {
    let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
    return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + keyName
  }

  /// 菜单里显示用；按当前键盘布局取字符，取不到返回 nil
  var keyEquivalent: KeyEquivalent? {
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
    statusScreen

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
    case .pinClipboard: "钉住剪贴板里的图"
    case .statusScreen: "状态屏"
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
    // 状态屏（Z10）不设默认键：按了就拦住键盘鼠标，不能让人误触；设了键是进入列表里的第一个状态
    case .statusScreen: nil
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

  /// 快捷键页和菜单栏的分组（N13 / N15：同名同序）
  static let sections: [(title: String, actions: [HotKeyAction])] = [
    ("剪贴板与启动器", [.clipboard, .launcher]),
    ("翻译", [.selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate]),
    // 钉住剪贴板里的图排在最后：菜单栏、启动器里有钉图时紧接着是「隐藏 / 关闭全部钉图」（MenuExtra），钉图的几项挨在一起
    (
      "截图与录制",
      [
        .screenshot, .screenshotLastRegion, .recognizeText, .screenRecord, .audioRecord,
        .pinClipboard,
      ]
    ),
    // 菜单栏里这一节不画节标题，只有一项「状态屏」带子菜单（每个状态一行，AppDelegate.buildStatusMenu）
    ("状态屏", [.statusScreen]),
  ]

  /// 种类色块里的符号
  var symbol: String {
    switch self {
    case .clipboard: "doc.on.clipboard.fill"
    case .launcher: "command"
    case .selectionTranslate: "character.bubble.fill"
    case .inputTranslate: "character.cursor.ibeam"
    case .translateReplace: "arrow.left.arrow.right"
    // 截图家族同一个动作到处同一个图标（体检 B44）：截图翻译 = translate，识字 = text.viewfinder（同截图工具栏、剪贴板 ⌘K）
    case .screenshotTranslate: "translate"
    case .screenshot: "camera.viewfinder"
    case .screenshotLastRegion: "rectangle.dashed"
    case .recognizeText: "text.viewfinder"
    case .screenRecord: "record.circle"
    case .audioRecord: "waveform"
    // 同速查表的「钉图」组、常驻缩略图的钉图钮；不用 pin：菜单里紧挨着的「隐藏全部钉图」是它
    case .pinClipboard: "pin.fill"
    case .statusScreen: "hand.raised.fill"
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
      .pinClipboard:
      Style.Family.screenshot
    case .statusScreen: Style.Family.statusScreen
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
  /// 正在录制的动作（设置 › 快捷键）：同一时刻只录一个，点了别的录制框，前一个就停下
  var recording: HotKeyAction?
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

  func setHandler(for action: HotKeyAction, _ handler: @escaping () -> Void) {
    handlers[action] = handler
  }

  /// 按偏好重新注册全部热键
  func reload() {
    suspend()
    installHandlerIfNeeded()
    for (index, action) in HotKeyAction.allCases.enumerated() {
      guard let hotKey = action.hotKey else { continue }
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
  }

  /// 注销全部（录制快捷键期间，免得按到现有组合就触发）
  func suspend() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs = []
    bindings = [:]
    failures = [:]
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
    return switch Int(status) {
    case eventInternalErr where optionOnly, eventHotKeyInvalidErr where optionOnly:
      "macOS 15.0 / 15.1 不支持只带 ⌥ 的组合，加上 ⌘ 或 ⌃ 再录一次"
    case eventHotKeyExistsErr: "和本 App 的另一个快捷键重复，没有注册上"
    default: "没有注册上（错误 \(status)），换一个组合试试"
    }
  }

  private func fire(_ id: UInt32) {
    if id == Self.escapeID { return escapePressed() }
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
