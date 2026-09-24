// 全局热键（Carbon RegisterEventHotKey，唯一能「按下即消费」的公开 API）。
// 默认非独占注册：别的 App 注册了同一组合也会成功，按一次两边都响应（PLAN §9）。

import AppKit
import Carbon.HIToolbox

struct HotKey: Hashable {
  /// 虚拟键码（kVK_*，按物理键位）
  var keyCode: UInt32
  /// Carbon 修饰键位：cmdKey / shiftKey / optionKey / controlKey
  var modifiers: UInt32

  static let clipboardDefault = HotKey(
    keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
  static let inputTranslateDefault = HotKey(
    keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(cmdKey | shiftKey))
}

final class HotKeyCenter {
  private static let signature: OSType = 0x4B54_5459  // 'KTTY'
  private var actions: [UInt32: () -> Void] = [:]
  private var refs: [EventHotKeyRef] = []
  private var handlerRef: EventHandlerRef?

  /// 注册成功返回 noErr；失败原样返回 OSStatus（如 15.0/15.1 上只带 ⌥ 的组合是 -9868）
  @discardableResult
  func register(_ hotKey: HotKey, action: @escaping () -> Void) -> OSStatus {
    installHandlerIfNeeded()
    let id = UInt32(actions.count + 1)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      hotKey.keyCode, hotKey.modifiers, EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(), 0, &ref)
    guard status == noErr, let ref else { return status }
    refs.append(ref)
    actions[id] = action
    return noErr
  }

  func unregisterAll() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs = []
    actions = [:]
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
          Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().actions[hotKeyID.id]?()
        }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
  }
}
