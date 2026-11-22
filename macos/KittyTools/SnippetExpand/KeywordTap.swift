// 片段展开的事件拦截（插件，2026-11-22，拍板页 https://claude.ai/artifact/PNApPJNxAgNG36JcSC1q1B Q3 Q4 Q12；PLAN §10「片段展开」）：
// **全仓库第五处事件拦截**（mac-overlay-panel §11）。它看得到每一个按键，红线：
// - 不吞、不改任何事件：先建「只听」的（系统不等它，Kitty 卡住也绝不拖慢打字）；只有辅助功能、建不起只听的时，换成
//   会话层不吞键的那种（同访达那处，只要辅助功能，第 0 批实测）
// - 打的字只进 KeyBuffer（内存里最长的关键词那么多个字）：不存盘、不进日志、不出这条线程；认出关键词才把「哪个关键词、
//   发给哪个进程、第几个键」投回主线程（SnippetExpander 决定展不展开）
// - 只收按下（keyDown）和鼠标按下（清空）；建在会话层加了注解的那一点（.cgAnnotatedSessionEventTap），事件上带着要送去的
//   进程（eventTargetUnixProcessID）：换了进程就清空——启动器这类不激活的面板浮在别的 App 上时，前台还是那个 App、键却是给面板的
// - 自己发的键（删关键词的 ⌫）带记号（marker），认出来不看
// - 在**单独的线程**上（同 MediaKeys / FinderKeys：主线程卡住时全系统打字不跟着卡），回调里不碰 AppKit
// - 被系统停掉就重新打开；回到前台、醒来时整条重建（SnippetExpander.refresh）；一条片段都没设关键词时不建
// - 安全输入开着时（密码框）系统一个键都不给，什么都不用做（2026-11-22 探针实测）

import AppKit
import Carbon.HIToolbox
import OSLog
import Synchronization

nonisolated enum KeywordTap {
  /// 自己发的键带的记号（CGEvent 的 eventSourceUserData）
  static let marker: Int64 = 0x4B49_5454_534E_4950

  /// 认出来的一个关键词
  struct Match: Sendable, Equatable {
    var keyword: String
    /// 这一下要送去的进程（0 = 不知道）
    var pid: Int32
    /// 这是第几个键（主线程动手前比一比：这期间又打了字就不动，免得删错字）
    var sequence: Int
  }

  /// 拦截线程和主线程共用的：关键词（主线程写、拦截线程读）、打到第几个键、认出来时投回主线程的回调
  final class Shared: NSObject, Sendable {
    let keywords = Mutex<Set<String>>([])
    let sequence = Atomic<Int>(0)
    let matched: @Sendable (Match) -> Void

    init(matched: @escaping @Sendable (Match) -> Void) { self.matched = matched }

    /// 在拦截线程上跑（stop 排过去的）：把这一轮 run loop 转停，线程已经 cancel、随后退出
    @objc func wake() { CFRunLoopStop(CFRunLoopGetCurrent()) }
  }

  /// 只在拦截线程上用的：端口（被系统停掉时拿它重新打开）、攒着的字、上一个键发给的进程
  private final class Box {
    let shared: Shared
    var port: CFMachPort?
    var buffer = KeyBuffer()
    var pid: Int32 = 0

    init(shared: Shared) { self.shared = shared }
  }

  /// 起一条拦截线程。建不起来、或者没让它停它自己停了（端口失效）时调 failed（在拦截线程上：调用方自己投回主线程）
  static func start(shared: Shared, failed: @escaping @Sendable () -> Void) -> Thread {
    let thread = Thread {
      let box = Box(shared: shared)
      let mask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
      let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let box = Unmanaged<Box>.fromOpaque(refcon).takeUnretainedValue()
        autoreleasepool { KeywordTap.handle(box, type, event) }
        return Unmanaged.passUnretained(event)
      }
      let refcon = Unmanaged.passUnretained(box).toOpaque()
      // 先只听；没有「输入监控」授权时不试（试了系统可能弹一个没人要的授权框），直接建只要辅助功能、不吞键的那种
      let listening =
        CGPreflightListenEventAccess()
        ? CGEvent.tapCreate(
          tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
          eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon) : nil
      guard
        let port = listening
          ?? CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: refcon)
      else {
        Log.clipboard.error("片段展开：事件拦截建不起来")
        return failed()
      }
      Log.clipboard.notice(
        "片段展开：事件拦截是\(listening == nil ? "不吞键的" : "只听的", privacy: .public)")
      box.port = port
      CFRunLoopAddSource(
        CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
      CGEvent.tapEnable(tap: port, enable: true)
      // 一直转到 stop（cancel + 往这条线程上排一个 wake 把这一轮转停）；端口失效了（.finished）就退出
      while !Thread.current.isCancelled {
        if CFRunLoopRunInMode(.defaultMode, 3600, false) == .finished { break }
      }
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
      withExtendedLifetime(box) {}
      if !Thread.current.isCancelled { failed() }
    }
    thread.name = "kitty.snippet-keywords"
    thread.qualityOfService = .userInteractive
    thread.start()
    return thread
  }

  /// 停：cancel，再往那条线程上排一个转停 run loop 的块（同 ScrollTap.stop）
  static func stop(_ thread: Thread, shared: Shared) {
    thread.cancel()
    shared.perform(#selector(Shared.wake), on: thread, with: nil, waitUntilDone: false)
  }

  /// 删掉打出来的关键词：按 count 下 ⌫（带记号，拦截不看）。发到会话层，和真的按键一样送到收键的窗口
  @MainActor static func deleteBackward(_ count: Int) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for _ in 0..<count {
      for keyDown in [true, false] {
        guard
          let event = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: keyDown)
        else { continue }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cgSessionEventTap)
      }
    }
  }

  // MARK: 拦截线程上

  private static func handle(_ box: Box, _ type: CGEventType, _ event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
      return
    }
    guard event.getIntegerValueField(.eventSourceUserData) != marker else { return }
    let sequence = box.shared.sequence.add(1, ordering: .relaxed).newValue
    guard type == .keyDown else {
      box.buffer.reset()
      return
    }
    let pid = Int32(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
    if pid != box.pid {
      box.buffer.reset()
      box.pid = pid
    }
    var length = 0
    var units = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(
      maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
    let key = KeyBuffer.classify(
      code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
      characters: String(utf16CodeUnits: units, count: min(length, units.count)))
    let keywords = box.shared.keywords.withLock { $0 }
    box.buffer.capacity = (keywords.map(\.count).max() ?? SnippetKeyword.maxLength) + 1
    guard let keyword = box.buffer.press(key, keywords: keywords) else { return }
    box.shared.matched(Match(keyword: keyword, pid: pid, sequence: sequence))
  }
}
