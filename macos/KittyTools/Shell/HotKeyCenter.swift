// 全局热键（Carbon RegisterEventHotKey，唯一能「按下即消费」的公开 API）。
// 每个动作的组合存在 UserDefaults；清除后为 nil、不注册。默认非独占注册：别的 App 注册了同一组合也会成功，
// 按一次两边都响应，且检测不到这种跨进程冲突（M1 实测，见 mac-overlay-panel 技能）。

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
    case .clipboard: HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey)
    case .selectionTranslate: HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | shiftKey)
    case .inputTranslate: HotKey(keyCode: kVK_ANSI_I, modifiers: cmdKey | shiftKey)
    // 用户旧版实际用的键；不占各 App 的 ⌘⇧S「另存为」。15.0–15.1 上只带 ⌥ 的组合注册不了，快捷键页会提示
    case .screenshotTranslate: HotKey(keyCode: kVK_ANSI_S, modifiers: optionKey)
    // 用户旧版实际用的键（15.0–15.1 上只带 ⌥ 的组合注册不了，快捷键页会提示）
    case .launcher: HotKey(keyCode: kVK_Space, modifiers: optionKey)
    // 用户旧版实际用的键（同上，15.0–15.1 注册不了会提示）
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
}

@Observable final class HotKeyCenter {
  /// 当前生效的组合（菜单显示用）
  private(set) var bindings: [HotKeyAction: HotKey] = [:]
  /// 注册失败的动作及 OSStatus（-9868：15.0/15.1 上只带 ⌥ 的组合；-9878：本进程重复）
  private(set) var failures: [HotKeyAction: OSStatus] = [:]
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

  private func fire(_ id: UInt32) {
    guard Int(id) < HotKeyAction.allCases.count else { return }
    handlers[HotKeyAction.allCases[Int(id)]]?()
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
