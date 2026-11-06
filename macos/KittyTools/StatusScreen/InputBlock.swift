// 状态屏的事件拦截（PLAN §10「状态屏」）：全仓库唯一碰 CGEvent.tapCreate 的地方。
// 会话层、头插、会吞事件的拦截（只要「辅助功能」授权，第 0 批实测）：按键、修饰键、鼠标键、滚轮、手势一律吞，媒体 / 亮度这类键
// 也吞；鼠标移动和左键、右键拖动不拦（退出提示靠鼠标移动浮出来）。吞掉之后别的 App、系统快捷键、注册成全局热键的组合都收不到。
// 安全输入开着时（密码框、终端的「安全键盘输入」）拦截一个按键都看不到，那时按键靠 key 面板接（StatusScreenPanel）。
// 向上只报退出判断和「挡下几次」要的那几样（Event）：修饰键也当键报（按下 / 松开看它那一位标志在不在），大写锁定每按一下
// 翻一次、没有「按着」，报成一次触碰。回调在主线程（源加在主运行环上）；主线程卡住时系统会停用拦截、
// 发一次停用通知——收到就重新打开，卡死不会把人锁在外面；通知万一没来，会话每分钟还会调一次 ensureEnabled()。
// 用完一定要 invalidate()：拦截活着的时候自己拿着自己一份引用，不作废就一直吞下去。
// 另有一个读会话状态的 isSessionAway（锁着屏、或切到了别的用户）：同是 CoreGraphics 的 C 接口，放在这里。

import AppKit

final class InputBlock {
  enum Event: Equatable {
    /// 按键按下：键码、是不是按住不放的连发、有没有带 ⌘ ⌃ ⌥ ⇧
    case keyDown(code: Int, isRepeat: Bool, hasModifiers: Bool)
    case keyUp(code: Int)
    /// 左键按下，位置是 AppKit 的全局坐标（原点在主屏左下）
    case leftDown(at: CGPoint)
    case leftUp
    /// 其他触碰：右键 / 其他鼠标键按下、媒体键按下、大写锁定
    case touch
    case scroll
  }

  /// 要拦的事件类型（CGEventType 的原始值）：左右键 1–4、按键和修饰键 10–12、媒体键 14、手势 18–20 / 29–31、滚轮 22、
  /// 其他鼠标键 25–27。都是第 0 批实测系统会留下的；**没有 5 / 6 / 7**（鼠标移动、左右键拖动）
  static let types: [UInt32] = [1, 2, 3, 4, 10, 11, 12, 14, 18, 19, 20, 22, 25, 26, 27, 29, 30, 31]
  /// 带了就算「带修饰键」的那四个：⇧ ⌃ ⌥ ⌘（大写锁定、fn 不算）
  private static let modifierMask =
    CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
    | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
  /// 修饰键的键码 → 它在标志里的那一位（左右两个键共用一位；kVK_Shift 56 / RightShift 60、Control 59 / 62、
  /// Option 58 / 61、Command 55 / 54、Function 63）。
  /// ponytail: 左右两个同名修饰键都按着、松开其中一个时那一位还在，会被当成又按了一下（多算一次触碰，那个键 5 秒后
  /// 才算松开，ExitHold.staleAfter）；要分清就看标志低位里分左右的设备位
  private static let modifierBits: [Int: UInt64] = [
    56: CGEventFlags.maskShift.rawValue, 60: CGEventFlags.maskShift.rawValue,
    59: CGEventFlags.maskControl.rawValue, 62: CGEventFlags.maskControl.rawValue,
    58: CGEventFlags.maskAlternate.rawValue, 61: CGEventFlags.maskAlternate.rawValue,
    55: CGEventFlags.maskCommand.rawValue, 54: CGEventFlags.maskCommand.rawValue,
    63: CGEventFlags.maskSecondaryFn.rawValue,
  ]
  /// kVK_CapsLock
  private static let capsLock = 57

  private let onEvent: (Event) -> Void
  private var port: CFMachPort?
  private var source: CFRunLoopSource?
  /// 暂停着（锁屏期间）：不吞、不报，系统的停用通知来了也不重新打开
  private(set) var isPaused = false

  /// 建不起来（没有辅助功能授权）返回 nil
  init?(onEvent: @escaping (Event) -> Void) {
    self.onEvent = onEvent
    let mask = Self.types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1) }
    // 回调拿到的是这个指针：拦截活着就不能让自己被放掉，这一份引用到 invalidate 才还
    let retained = Unmanaged.passRetained(self)
    let created = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        // 「拦截被停用」不是真事件，event 里是什么没有保证：先判它，不读任何字段
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
          MainActor.assumeIsolated {
            Unmanaged<InputBlock>.fromOpaque(info).takeUnretainedValue().ensureEnabled()
          }
          return Unmanaged.passUnretained(event)
        }
        // CGEvent 不是 Sendable，不带进主线程隔离的闭包：要的几样先在外面取成值
        let raw = type.rawValue
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags.rawValue
        let location = event.location
        // 类型 14（系统定义的事件）要看 subtype 和 data1，只有转成 NSEvent 才读得到
        let system = raw == 14 ? NSEvent(cgEvent: event) : nil
        let subtype = system.map { Int($0.subtype.rawValue) }
        let data1 = system?.data1 ?? 0
        let swallow = MainActor.assumeIsolated {
          Unmanaged<InputBlock>.fromOpaque(info).takeUnretainedValue().received(
            type: raw, code: code, isRepeat: isRepeat, flags: flags, location: location,
            subtype: subtype, data1: data1)
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
      }, userInfo: retained.toOpaque())
    guard let created else {
      retained.release()
      return nil
    }
    port = created
    let source = CFMachPortCreateRunLoopSource(nil, created, 0)
    // common 模式：菜单跟踪、模态面板期间照样拦
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    self.source = source
    CGEvent.tapEnable(tap: created, enable: true)
  }

  /// 锁屏期间：不拦输入（登录窗口要能点、能打字）
  func pause() {
    isPaused = true
    if let port { CGEvent.tapEnable(tap: port, enable: false) }
  }

  func resume() {
    isPaused = false
    if let port { CGEvent.tapEnable(tap: port, enable: true) }
  }

  /// 没暂停、却被系统停用了（回调卡住太久、或系统觉得该放行）：重新打开。停用通知来了会调；会话每分钟也调一次，
  /// 防通知没来（睡眠唤醒之后）
  func ensureEnabled() {
    guard !isPaused, let port, !CGEvent.tapIsEnabled(tap: port) else { return }
    CGEvent.tapEnable(tap: port, enable: true)
  }

  /// 这个登录会话现在不在用户手里：锁着屏，或切到了别的用户（会话字典里的 CGSSessionScreenIsLocked——锁着时才有这个键，
  /// 键名没有文档、但用了很多年；kCGSessionOnConsoleKey 是公开的）。状态屏拿它兜底：解锁的通知万一没到，轮询看得到
  static var isSessionAway: Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
    let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? true
    return locked || !onConsole
  }

  /// 作废：之后一个事件都不再吞。可以在自己的回调里调（退出判断就是在回调里做的）；调过再调不做事
  func invalidate() {
    guard let port else { return }
    self.port = nil
    CGEvent.tapEnable(tap: port, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    source = nil
    CFMachPortInvalidate(port)
    // 还 init 里那一份；放在最后（调用方手里还有引用，这里不会当场释放）
    Unmanaged.passUnretained(self).release()
  }

  private func received(
    type: UInt32, code: Int, isRepeat: Bool, flags: UInt64, location: CGPoint, subtype: Int?,
    data1: Int
  ) -> Bool {
    // 暂停那一刻还在路上的事件：放行
    guard !isPaused else { return false }
    // 只有左键按下要换算位置：别的事件（滚轮一秒上百个）不去问屏幕
    let isLeftDown = type == CGEventType.leftMouseDown.rawValue
    let (swallow, event) = Self.classify(
      type: type, code: code, isRepeat: isRepeat, flags: flags, location: location,
      primaryHeight: isLeftDown ? NSScreen.screens.first?.frame.height ?? 0 : 0, subtype: subtype,
      data1: data1)
    if let event { onEvent(event) }
    return swallow
  }

  /// 一个事件吞不吞、向上报什么（纯函数）。类型 14 只吞 subtype 8（媒体 / 亮度这类键：data1 高 16 位是哪个键，
  /// 接着 8 位 0xA 按下 / 0xB 松开，最低位是连发），别的 subtype 放行；其余要了的类型一律吞。
  /// 修饰键按那一位标志在不在报成按下（算带修饰键：起不了「按住 esc」，还会取消正在按住的）/ 松开，大写锁定报成一次触碰；
  /// 松开的右键 / 其他键、其他键拖动、手势只吞不报
  static func classify(
    type: UInt32, code: Int, isRepeat: Bool, flags: UInt64, location: CGPoint,
    primaryHeight: CGFloat, subtype: Int?, data1: Int
  ) -> (swallow: Bool, event: Event?) {
    switch type {
    case CGEventType.keyDown.rawValue:
      (true, .keyDown(code: code, isRepeat: isRepeat, hasModifiers: flags & modifierMask != 0))
    case CGEventType.keyUp.rawValue: (true, .keyUp(code: code))
    case CGEventType.flagsChanged.rawValue:
      if code == capsLock {
        (true, .touch)
      } else if let bit = modifierBits[code] {
        (
          true,
          flags & bit != 0
            ? .keyDown(code: code, isRepeat: false, hasModifiers: true) : .keyUp(code: code)
        )
      } else {
        (true, nil)
      }
    case CGEventType.leftMouseDown.rawValue:
      (true, .leftDown(at: appKitPoint(location, primaryHeight: primaryHeight)))
    case CGEventType.leftMouseUp.rawValue: (true, .leftUp)
    case CGEventType.rightMouseDown.rawValue, CGEventType.otherMouseDown.rawValue: (true, .touch)
    case CGEventType.scrollWheel.rawValue: (true, .scroll)
    case 14:
      subtype == 8
        ? (true, (data1 >> 8) & 0xFF == 0xA && data1 & 1 == 0 ? .touch : nil) : (false, nil)
    default: (types.contains(type), nil)
    }
  }

  /// CGEvent 的位置（原点在主屏左上、y 向下）→ AppKit 的全局坐标（原点在主屏左下）
  static func appKitPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: primaryHeight - point.y)
  }
}
