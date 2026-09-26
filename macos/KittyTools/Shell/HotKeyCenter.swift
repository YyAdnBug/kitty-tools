// 全局热键（Carbon RegisterEventHotKey，唯一能「按下即消费」的公开 API）。
// 每个动作的组合存在 UserDefaults；清除后为 nil、不注册。默认非独占注册：别的 App 注册了同一组合也会成功，
// 按一次两边都响应，且检测不到这种跨进程冲突（M1 实测，见 mac-overlay-panel 技能）。
// 另外给界面用：动作的分组 / 色块（快捷键页、速查表、引导、菜单栏共用）、注册失败的原因、最近一次触发（引导「按一下试试」）。

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

struct HotKey: Codable, Hashable {
  /// 虚拟键码（kVK_*，按物理键位）
  var keyCode: UInt32
  /// Carbon 修饰键位：cmdKey / shiftKey / optionKey / controlKey
  var modifiers: UInt32

  /// 录制时从按键事件构造；没有 ⌘ / ⌃ / ⌥ 的组合（F1–F20 除外）不能当全局热键，会吞掉正常输入
  init?(event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var modifiers = 0
    if flags.contains(.command) { modifiers |= cmdKey }
    if flags.contains(.option) { modifiers |= optionKey }
    if flags.contains(.control) { modifiers |= controlKey }
    let isFunctionKey = Self.functionKeys.keys.contains(Int(event.keyCode))
    guard modifiers != 0 || isFunctionKey else { return nil }
    if flags.contains(.shift) { modifiers |= shiftKey }
    self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers))
  }

  init(keyCode: Int, modifiers: Int) {
    self.keyCode = UInt32(keyCode)
    self.modifiers = UInt32(modifiers)
  }

  init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

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
    screenshotLastRegion, recognizeText, translateReplace

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
    // Bob 的输入翻译用 ⌥A，这里 ⌥A 给了截图
    case .inputTranslate: HotKey(keyCode: kVK_ANSI_I, modifiers: cmdKey | shiftKey)
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
    }
  }

  /// 没存过 → 默认组合；存了空数据 → 已清除（nil）
  var hotKey: HotKey? {
    get {
      guard let data = UserDefaults.standard.data(forKey: prefsKey) else { return defaultHotKey }
      return try? JSONDecoder().decode(HotKey.self, from: data)
    }
    nonmutating set {
      let data = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data()
      UserDefaults.standard.set(data, forKey: prefsKey)
    }
  }

  private var prefsKey: String { "hotkey." + rawValue }

  /// 快捷键页和菜单栏的分组（N13 / N15：同名同序）
  static let sections: [(title: String, actions: [HotKeyAction])] = [
    ("剪贴板与启动器", [.clipboard, .launcher]),
    ("翻译", [.selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate]),
    ("截图", [.screenshot, .screenshotLastRegion, .recognizeText]),
  ]

  /// 种类色块里的符号
  var symbol: String {
    switch self {
    case .clipboard: "doc.on.clipboard.fill"
    case .launcher: "command"
    case .selectionTranslate: "character.bubble.fill"
    case .inputTranslate: "character.cursor.ibeam"
    case .translateReplace: "arrow.left.arrow.right"
    case .screenshotTranslate: "text.viewfinder"
    case .screenshot: "camera.viewfinder"
    case .screenshotLastRegion: "rectangle.dashed"
    case .recognizeText: "text.magnifyingglass"
    }
  }

  /// 功能家族色（截图翻译算翻译，和菜单栏一致）
  var color: Color {
    switch self {
    case .clipboard: Style.Family.clipboard
    case .launcher: Style.Family.command
    case .selectionTranslate, .inputTranslate, .translateReplace, .screenshotTranslate:
      Style.Family.translate
    case .screenshot, .screenshotLastRegion, .recognizeText: Style.Family.screenshot
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
  private static let signature: OSType = 0x4B54_5459  // 'KTTY'

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
    guard Int(id) < HotKeyAction.allCases.count else { return }
    let action = HotKeyAction.allCases[Int(id)]
    lastFired = action
    fireCount += 1
    handlers[action]?()
  }

  private func installHandlerIfNeeded() {
    guard handlerRef == nil else { return }
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
