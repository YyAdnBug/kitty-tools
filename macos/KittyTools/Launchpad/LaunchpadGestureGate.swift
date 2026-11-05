// macOS 26：Kitty 已打开时，整段捏合 / 张开只给原始触点识别器，不再同时触发系统桌面。
// 会话头插只监听私有手势 29 / 30，不收键鼠；只吞 Dock 的 scale 轴，不生成事件、不改系统设置。
// 依据本机 Dock 26 的字段读取和 DOCKGestures 分发；私有布局变更时放行，其他系统版本不安装。

import AppKit
import OSLog

@MainActor final class LaunchpadGestureGate {
  nonisolated struct Ownership {
    enum Owner { case system, kitty }
    private(set) var owner: Owner?

    mutating func reset() { owner = nil }

    /// 只在 began 决定归属：Kitty 中途打开不追吞，中途收起也吞完原来的一整段。
    mutating func swallow(
      type: UInt32, hid: Int64, motion: Int64, phase: Int64, isOpen: Bool
    ) -> Bool {
      if type == 29 {
        guard hid == 60 else { return false }
        let result = owner == .kitty
        reset()
        return result
      }
      guard type == 30, hid == 23, motion & 0xffff == 3 else { return false }
      if phase & 0xc != 0 {
        let result = owner == .kitty
        reset()
        return result
      }
      if phase & 1 != 0 {
        // 重复 began 不能因面板中途收起 / 打开而改变本次归属。
        if owner == nil { owner = isOpen ? .kitty : .system }
        return owner == .kitty
      }
      if phase == 2 { return owner == .kitty }
      // 缺 began、未知阶段或重新连接时不猜，不补造系统事件。
      reset()
      return false
    }
  }

  var isLaunchpadOpen: () -> Bool = { false }
  private var ownership = Ownership()
  private var port: CFMachPort?
  private var source: CFRunLoopSource?
  isolated deinit { stop() }

  func start() {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
      Permissions.isAccessibilityTrusted
    else {
      stop()
      return
    }
    if let port, CFMachPortIsValid(port) {
      if !CGEvent.tapIsEnabled(tap: port) { recover() }
      return
    }
    stop()
    let mask = (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
    guard
      let created = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: launchpadGestureGateEvent,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      Log.launchpad.debug("native gesture tap unavailable")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(nil, created, 0) else {
      CFMachPortInvalidate(created)
      return
    }
    port = created
    self.source = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: created, enable: true)
    Log.launchpad.debug("native gesture tap connected")
  }

  func stop() {
    ownership.reset()
    if let port { CGEvent.tapEnable(tap: port, enable: false) }
    if let source {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFRunLoopSourceInvalidate(source)
    }
    source = nil
    if let port { CFMachPortInvalidate(port) }
    port = nil
  }

  fileprivate func recover() {
    ownership.reset()
    guard Permissions.isAccessibilityTrusted else {
      stop()
      return
    }
    if let port { CGEvent.tapEnable(tap: port, enable: true) }
    Log.launchpad.debug("native gesture tap recovered; ownership reset")
  }

  fileprivate func received(
    type: UInt32, hid: Int64, motion: Int64, phase: Int64
  ) -> Bool {
    guard port != nil, Permissions.isAccessibilityTrusted else {
      stop()
      return false
    }
    let open = isLaunchpadOpen()
    let swallow = ownership.swallow(
      type: type, hid: hid, motion: motion, phase: phase, isOpen: open)
    return swallow
  }
}

nonisolated private func launchpadGestureGateEvent(
  _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
  _ context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let context else { return Unmanaged.passUnretained(event) }
  let gate = Unmanaged<LaunchpadGestureGate>.fromOpaque(context).takeUnretainedValue()
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    MainActor.assumeIsolated { gate.recover() }
    return Unmanaged.passUnretained(event)
  }
  let raw = type.rawValue
  let hid = event.getIntegerValueField(CGEventField(rawValue: 110)!)
  let motion = event.getIntegerValueField(CGEventField(rawValue: 123)!)
  let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
  let swallow = MainActor.assumeIsolated {
    gate.received(type: raw, hid: hid, motion: motion, phase: phase)
  }
  return swallow ? nil : Unmanaged.passUnretained(event)
}
