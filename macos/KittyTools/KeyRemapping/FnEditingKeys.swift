// 补齐没有 Apple Fn 转换表的键盘。Globe 本身仍由 HID 映射发给系统。

import AppKit
import Carbon.HIToolbox

final class FnEditingKeys {
  private var box: EventBox?

  func start() -> Bool {
    if box != nil { return true }
    let box = EventBox()
    let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) {
      $0 | (1 << $1.rawValue)
    }
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: { _, type, event, context in
        let box = Unmanaged<EventBox>.fromOpaque(context!).takeUnretainedValue()
        box.handle(type, event)
        return Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(box).toOpaque())
    else { return false }
    box.port = port
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    self.box = box
    return true
  }

  func stop() {
    guard let port = box?.port else { return }
    CFMachPortInvalidate(port)
    box = nil
  }

  /// 只在主线程 run loop 的事件回调里读写。按下、重复和松开使用同一个目标键码。
  private nonisolated final class EventBox {
    var port: CFMachPort?
    private var fnIsDown = false
    private var translated: [Int: Int] = [:]

    private static let editingCodes = [
      kVK_Delete: kVK_ForwardDelete, kVK_Return: kVK_ANSI_KeypadEnter,
      kVK_LeftArrow: kVK_Home, kVK_RightArrow: kVK_End,
      kVK_UpArrow: kVK_PageUp, kVK_DownArrow: kVK_PageDown,
    ]

    func handle(_ type: CGEventType, _ event: CGEvent) {
      if type == .tapDisabledByTimeout, let port {
        fnIsDown = false
        CGEvent.tapEnable(tap: port, enable: true)
        return
      }
      let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
      let hasFnFlag = event.flags.contains(.maskSecondaryFn)
      if type == .flagsChanged, code == kVK_Function { fnIsDown = hasFnFlag }
      guard let mapped = Self.editingCodes[code] else { return }
      let target: Int?
      switch type {
      case .keyDown:
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
          // 方向键自己带 Fn 标志。退格和 Return 可以直接根据标志判断。
          let held = code == kVK_Delete || code == kVK_Return ? hasFnFlag : fnIsDown
          translated[code] = held ? mapped : nil
        }
        target = translated[code]
      case .keyUp:
        target = translated.removeValue(forKey: code)
      default:
        return
      }
      if let target { event.setIntegerValueField(.keyboardEventKeycode, value: Int64(target)) }
    }
  }
}
