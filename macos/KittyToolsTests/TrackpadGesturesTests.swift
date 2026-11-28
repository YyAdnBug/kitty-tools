// 触控板手势插件（TrackpadGestures/）：识别（FingerGesture、TapSequence——Trackpad Edges 的 GestureChecks.swift 里多指和角落的那几条
// 照搬过来，他按主线程定时器 consumePress 的长按改成看帧的时间）、主线程上轻点 / 双击怎么分（TapDispatch）、角落的一下让给点按
// （ClickYield）、偏好里那一段的读写（认不出的行原样留着）、听哪几种、按 App 停用、系统的三指手势，和 G1（收帧的闭包在后台线程上调不 trap）。
// **不订真的 Touchpad、不注册框架的回调、不读真触点**；系统的触控板设置读临时偏好域。

import Foundation
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct TrackpadGesturesTests {
  /// 他的 fingers(_:x:)：一排按着的手指，id 从 1 起、横着隔 0.08
  private static func fingers(_ count: Int, x: Double = 0.3) -> [TouchPoint] {
    (1...count).map { TouchPoint(id: Int32($0), x: x + 0.08 * Double($0), y: 0.5, state: 4) }
  }

  /// GestureChecks.swift 里多指的那几条：轻点按最多同时几根算、一根根抬起来也算；挪了不算；太久不算；长按过的抬起来不算轻点
  @Test func tapsAndHoldsFromTrackpadEdges() {
    var gesture = FingerGesture()
    func frame(_ touches: [TouchPoint], _ time: Double) -> FingerGesture.Event? {
      gesture.update(touches, at: time)
    }
    #expect(frame(Self.fingers(3), 6) == nil)
    #expect(gesture.holdCandidate == 3)
    #expect(frame([], 6.1) == .tap(fingers: 3))
    #expect(frame(Self.fingers(3), 7) == nil)
    #expect(frame(Self.fingers(4), 7.04) == nil)
    #expect(gesture.holdCandidate == 4)
    #expect(frame(Array(Self.fingers(4).dropLast()), 7.1) == nil)
    #expect(gesture.holdCandidate == nil)
    #expect(frame([], 7.2) == .tap(fingers: 4))
    // 他的 consumePress（0.55 s 的定时器到点再认一次）：这里看帧的时间，到点算一次，之后再按着、抬起来都不算
    #expect(frame(Self.fingers(4), 8) == nil)
    #expect(frame(Self.fingers(4), 8.3) == nil)
    #expect(frame(Self.fingers(4), 8.56) == .hold(fingers: 4))
    #expect(frame(Self.fingers(4), 8.7) == nil)
    #expect(gesture.holdCandidate == nil)
    #expect(frame([], 8.8) == nil)
    #expect(frame(Self.fingers(3), 9) == nil)
    #expect(frame(Self.fingers(3, x: 0.4), 9.1) == nil)
    #expect(gesture.holdCandidate == nil)
    #expect(frame([], 9.2) == nil)
    #expect(frame(Self.fingers(5), 10) == nil)
    #expect(frame([], 10.4) == nil)
    #expect(gesture.idle)
  }

  /// 一根手指在某个角
  private static func finger(_ x: Double, _ y: Double, id: Int32 = 1) -> [TouchPoint] {
    [TouchPoint(id: id, x: x, y: y, state: 4)]
  }

  /// GestureChecks.swift 里角落的那几条，加上：四个角各认对（9%，y = 1 是上沿；左下角那个点是 2026-11-28 真机探针里的）、
  /// 挪了没过 slop 却出了角不算、两根手指 / 换了一根手指不算、太久不算、角落不认长按、单指在中间和边上不算
  @Test func cornerTaps() {
    var gesture = FingerGesture()
    func frame(_ touches: [TouchPoint], _ time: Double) -> FingerGesture.Event? {
      gesture.update(touches, at: time)
    }
    #expect(frame(Self.finger(0.04, 0.04), 11) == nil)
    #expect(frame([], 11.1) == .corner(.bottomLeft))
    #expect(frame(Self.finger(0.96, 0.96), 12) == nil)
    #expect(frame(Self.finger(0.89, 0.96), 12.1) == nil)
    #expect(frame([], 12.2) == nil)
    let corners: [(Double, Double, FingerGesture.Corner)] = [
      (0.02, 0.98, .topLeft), (0.97, 0.93, .topRight), (0.004, 0.008, .bottomLeft),
      (0.95, 0.05, .bottomRight),
    ]
    for (index, (x, y, corner)) in corners.enumerated() {
      let start = 20 + Double(index)
      #expect(frame(Self.finger(x, y), start) == nil)
      #expect(frame(Self.finger(x, y), start + 0.2) == nil)
      #expect(frame([], start + 0.3) == .corner(corner), "\(corner)")
    }
    // 挪了 0.01（没过 slop）却出了角
    #expect(frame(Self.finger(0.085, 0.95), 30) == nil)
    #expect(frame(Self.finger(0.095, 0.95), 30.05) == nil)
    #expect(frame([], 30.1) == nil)
    // 两根手指都在角上；一根抬起来又换了一根
    #expect(frame(Self.finger(0.03, 0.03) + Self.finger(0.06, 0.05, id: 2), 31) == nil)
    #expect(frame([], 31.1) == nil)
    #expect(frame(Self.finger(0.03, 0.03), 32) == nil)
    #expect(frame(Self.finger(0.03, 0.04, id: 2), 32.05) == nil)
    #expect(frame([], 32.1) == nil)
    // 太久；按着一秒也不算长按（拇指搭在角上）
    #expect(frame(Self.finger(0.03, 0.03), 33) == nil)
    #expect(frame(Self.finger(0.03, 0.03), 33.6) == nil)
    #expect(frame(Self.finger(0.03, 0.03), 34) == nil)
    #expect(frame([], 34.1) == nil)
    // 中间、左边缘中间
    #expect(frame(Self.finger(0.5, 0.5), 35) == nil)
    #expect(frame([], 35.1) == nil)
    #expect(frame(Self.finger(0.05, 0.5), 36) == nil)
    #expect(frame([], 36.1) == nil)
    #expect(FingerGesture.Corner(x: 0.1, y: 0.95) == nil)
    #expect(FingerGesture.Corner(x: 0.95, y: 0.1) == nil)
    #expect(gesture.idle)
  }

  /// 长按的候选变了（多落下一根）从那一帧重新算，前面三指那一段不算进来
  @Test func holdRestartsWhenTheFingerCountChanges() {
    var gesture = FingerGesture()
    #expect(gesture.update(Self.fingers(3), at: 0) == nil)
    #expect(gesture.update(Self.fingers(4), at: 0.3) == nil)
    #expect(gesture.update(Self.fingers(4), at: 0.6) == nil)
    #expect(gesture.update(Self.fingers(4), at: 0.86) == .hold(fingers: 4))
    // 挪了一点点（没过 0.035 / 0.05）照样算
    var drift = FingerGesture()
    #expect(drift.update(Self.fingers(5), at: 0) == nil)
    let moved = Self.fingers(5).map { TouchPoint(id: $0.id, x: $0.x + 0.03, y: 0.54, state: 4) }
    #expect(drift.update(moved, at: 0.6) == .hold(fingers: 5))
  }

  /// 只认真按着的（悬着的、正在离开的不算）；两指、六指不算；抬起一根又落下另一根的不算
  @Test func onlyTouchingFingersCount() {
    var gesture = FingerGesture()
    let hovering = Self.fingers(3) + [TouchPoint(id: 9, x: 0.9, y: 0.5, state: 2)]
    #expect(gesture.update(hovering, at: 0) == nil)
    #expect(
      gesture.update([TouchPoint(id: 1, x: 0.38, y: 0.5, state: 5)], at: 0.1) == .tap(fingers: 3))
    #expect(gesture.update(Self.fingers(2), at: 1) == nil)
    #expect(gesture.update([], at: 1.1) == nil)
    #expect(gesture.update(Self.fingers(6, x: 0.2), at: 2) == nil)
    #expect(gesture.update([], at: 2.1) == nil)
    let three = Self.fingers(3)
    #expect(gesture.update(three, at: 3) == nil)
    #expect(gesture.update(Array(three.prefix(2)), at: 3.05) == nil)
    let swapped = Array(three.prefix(2)) + [TouchPoint(id: 7, x: 0.62, y: 0.5, state: 4)]
    #expect(gesture.update(swapped, at: 3.1) == nil)
    #expect(gesture.update([], at: 3.2) == nil)
  }

  /// 他的 TapSequence 那几条（前台 App 那一维换成设备）：0.29 s 内同一种第二下 = 双击，别的手指数、别的设备各等各的
  @Test func doubleTapsPairTheSameDeviceAndFingers() throws {
    var sequence = TapSequence()
    // 宏里不能直接调会改它的方法：经两个小函数
    func tap(_ key: TapSequence.Key, _ time: Double) -> TapSequence.Pending? {
      sequence.tap(key, at: time)
    }
    func take(_ pending: TapSequence.Pending) -> Bool { sequence.takeSingle(pending) }
    let three = TapSequence.Key(device: 1, source: .fingers(3))
    let four = TapSequence.Key(device: 1, source: .fingers(4))
    let otherDevice = TapSequence.Key(device: 2, source: .fingers(3))
    let corner = TapSequence.Key(device: 1, source: .corner(.bottomLeft))
    let cornerSingle = try #require(tap(corner, 12.98))
    let threeSingle = try #require(tap(three, 13))
    let fourSingle = try #require(tap(four, 13.03))
    let otherSingle = try #require(tap(otherDevice, 13.05))
    #expect(tap(three, 13.15) == nil)
    #expect(tap(corner, 13.15) == nil)
    #expect(!take(threeSingle))
    #expect(!take(cornerSingle))
    #expect(take(fourSingle))
    #expect(take(otherSingle))
    // 过了 0.29 s 的第二下重新开始等，前一下作废
    let late = try #require(tap(three, 20))
    let next = try #require(tap(three, 20.3))
    #expect(!take(late))
    #expect(take(next))
  }

  /// 主线程上：没绑双击的轻点当场做（拍板 B1）；绑了双击，第一下等着，0.29 s 内第二下是双击、等着的那下作废，没有第二下就算轻点
  @Test func tapWaitsOnlyWhenADoubleTapIsBound() {
    var dispatch = TapDispatch()
    let tap = TrackpadGesture(fingers: 4, kind: .tap)
    let double = TrackpadGesture(fingers: 4, kind: .doubleTap)
    let four = TrackpadGesture.Source.fingers(4)
    #expect(dispatch.tap(device: 1, source: four, at: 0, bound: { $0 == tap }) == .fire(tap))
    #expect(dispatch.tap(device: 1, source: .fingers(3), at: 0, bound: { $0 == tap }) == .none)
    let both: (TrackpadGesture) -> Bool = { $0 == tap || $0 == double }
    guard case .wait(let first) = dispatch.tap(device: 1, source: four, at: 1, bound: both) else {
      Issue.record("绑了双击时第一下要等")
      return
    }
    #expect(dispatch.tap(device: 1, source: four, at: 1.2, bound: both) == .fire(double))
    #expect(dispatch.expire(first, bound: both) == nil)
    guard case .wait(let lone) = dispatch.tap(device: 1, source: four, at: 5, bound: both) else {
      Issue.record("绑了双击时第一下要等")
      return
    }
    #expect(dispatch.expire(lone, bound: both) == tap)
    // 只绑了双击：等够了什么都不做
    let onlyDouble: (TrackpadGesture) -> Bool = { $0 == double }
    guard case .wait(let alone) = dispatch.tap(device: 1, source: four, at: 9, bound: onlyDouble)
    else {
      Issue.record("绑了双击时第一下要等")
      return
    }
    #expect(dispatch.expire(alone, bound: onlyDouble) == nil)
  }

  /// 角落同一套：只绑了轻点的角当场做；绑了双击的等第二下。那个角的一下让给了点按（cancel）时在等的第一下作废、
  /// 之后的一下重新开始等，别的角不受影响
  @Test func cornerTapsDispatchLikeFingers() {
    var dispatch = TapDispatch()
    let bottomLeft = TrackpadGesture.Source.corner(.bottomLeft)
    let topRight = TrackpadGesture.Source.corner(.topRight)
    let leftTap = TrackpadGesture(corner: .bottomLeft, kind: .tap)
    let leftDouble = TrackpadGesture(corner: .bottomLeft, kind: .doubleTap)
    let rightTap = TrackpadGesture(corner: .topRight, kind: .tap)
    #expect(
      dispatch.tap(device: 1, source: topRight, at: 0, bound: { $0 == rightTap }) == .fire(rightTap)
    )
    let bound: (TrackpadGesture) -> Bool = { $0 == leftTap || $0 == leftDouble || $0 == rightTap }
    guard case .wait(let first) = dispatch.tap(device: 1, source: bottomLeft, at: 1, bound: bound)
    else {
      Issue.record("绑了双击时第一下要等")
      return
    }
    #expect(dispatch.tap(device: 1, source: topRight, at: 1.1, bound: bound) == .fire(rightTap))
    dispatch.cancel(device: 1, source: bottomLeft)
    #expect(dispatch.expire(first, bound: bound) == nil)
    guard case .wait(let again) = dispatch.tap(device: 1, source: bottomLeft, at: 1.2, bound: bound)
    else {
      Issue.record("作废之后的一下重新开始等")
      return
    }
    #expect(dispatch.tap(device: 1, source: bottomLeft, at: 1.4, bound: bound) == .fire(leftDouble))
    #expect(dispatch.expire(again, bound: bound) == nil)
  }

  /// 角落的一下让给点按：主线程收到前 0.5 s、后 0.15 s 里按下过鼠标（左右中键都算）就不做
  @Test func cornerTapsYieldToClicks() {
    #expect(!ClickYield.coincides(tapAt: 100, mouseDowns: []))
    #expect(ClickYield.coincides(tapAt: 100, mouseDowns: [99.7]))
    #expect(ClickYield.coincides(tapAt: 100, mouseDowns: [100.1]))
    #expect(ClickYield.coincides(tapAt: 100, mouseDowns: [99.55]))
    #expect(!ClickYield.coincides(tapAt: 100, mouseDowns: [99.4, 100.2]))
    #expect(ClickYield.coincides(tapAt: 100, mouseDowns: [99, 99.9, 101]))
  }

  /// 偏好里那一段：默认四指轻点是剪贴板历史；认得的按九种的先后写回，认不出的（更新版本的手指数、目标）照原样排在后面，
  /// 同一种两行只认第一行、没有等号的扔掉；设一种时它原来认不出的那一行一起换掉
  @Test func bindingsRoundTripAndKeepUnknownLines() {
    let fourTap = TrackpadGesture(fingers: 4, kind: .tap)
    let fiveHold = TrackpadGesture(fingers: 5, kind: .hold)
    let threeTap = TrackpadGesture(fingers: 3, kind: .tap)
    #expect(
      TrackpadGestureBindings(text: TrackpadGestureBindings.defaultText).targets == [
        fourTap: .action(.clipboard)
      ])
    var bindings = TrackpadGestureBindings(
      text: [
        "5.hold=command:script:/x/y.sh", "6.tap=action:clipboard", "3.tap=action:futureThing",
        "4.tap=action:launcher", "4.tap=action:clipboard", "nonsense", "3.doubleTap=url:https://x",
      ].joined(separator: "\n"))
    #expect(
      bindings.targets == [fourTap: .action(.launcher), fiveHold: .command("script:/x/y.sh")])
    #expect(
      bindings.text
        == "4.tap=action:launcher\n5.hold=command:script:/x/y.sh\n6.tap=action:clipboard\n"
        + "3.tap=action:futureThing\n3.doubleTap=url:https://x")
    bindings[threeTap] = .action(.screenshot)
    bindings[fourTap] = nil
    #expect(
      bindings.text
        == "3.tap=action:screenshot\n5.hold=command:script:/x/y.sh\n6.tap=action:clipboard\n"
        + "3.doubleTap=url:https://x")
    #expect(TrackpadGestureBindings(text: bindings.text) == bindings)
    #expect(TrackpadGestureBindings(text: "").isEmpty)
    #expect(TrackpadGestureBindings(text: "").text.isEmpty)
    #expect(TrackpadGesture(key: "5.doubleTap") == TrackpadGesture(fingers: 5, kind: .doubleTap))
    for key in ["2.tap", "6.hold", "4.tap.x", "four.tap", "4.", ".tap", "4.tripleTap"] {
      #expect(TrackpadGesture(key: key) == nil, "\(key)")
    }
    #expect(TrackpadGestureTarget(stored: "command:") == nil)
    #expect(TrackpadGestureTarget(stored: "action:") == nil)
    #expect(TrackpadGesture.all.count == 17)
  }

  /// 角落那八种：「bottomLeft.doubleTap=action:screenshot」，排在手指的后面；角落的长按、认不出的角原样留着；默认没有角落
  @Test func cornerBindingsRoundTrip() {
    let leftDouble = TrackpadGesture(corner: .bottomLeft, kind: .doubleTap)
    let rightTap = TrackpadGesture(corner: .topRight, kind: .tap)
    var bindings = TrackpadGestureBindings(
      text: [
        "bottomLeft.doubleTap=action:screenshot", "bottomLeft.hold=action:launcher",
        "middle.tap=action:clipboard", "4.tap=action:clipboard",
      ].joined(separator: "\n"))
    #expect(
      bindings.targets == [
        leftDouble: .action(.screenshot),
        TrackpadGesture(fingers: 4, kind: .tap): .action(.clipboard),
      ])
    bindings[rightTap] = .command("system:lock")
    #expect(
      bindings.text
        == "4.tap=action:clipboard\ntopRight.tap=command:system:lock\n"
        + "bottomLeft.doubleTap=action:screenshot\nbottomLeft.hold=action:launcher\n"
        + "middle.tap=action:clipboard")
    #expect(TrackpadGestureBindings(text: bindings.text) == bindings)
    #expect(TrackpadGesture(key: "topLeft.tap") == TrackpadGesture(corner: .topLeft, kind: .tap))
    #expect(TrackpadGesture(key: "bottomRight.hold") == nil)
    #expect(
      TrackpadGestureBindings(text: TrackpadGestureBindings.defaultText).targets.keys.allSatisfy {
        $0.fingers != nil
      })
    #expect(Set(TrackpadGesture.all.filter { $0.fingers == nil }.map(\.key)).count == 8)
  }

  /// 听哪几种：轻点、双击都要认轻点；一种都没绑 = 不听（不订触控板）
  @Test func listensOnlyForBoundFingerCounts() {
    #expect(TrackpadGestures.listening(for: []) == nil)
    #expect(
      TrackpadGestures.listening(for: [
        TrackpadGesture(fingers: 4, kind: .tap), TrackpadGesture(fingers: 3, kind: .doubleTap),
        TrackpadGesture(fingers: 5, kind: .hold),
      ]) == TrackpadGestures.Listening(taps: [3, 4], holds: [5]))
    #expect(
      TrackpadGestures.listening(for: [
        TrackpadGesture(corner: .bottomLeft, kind: .doubleTap),
        TrackpadGesture(corner: .topRight, kind: .tap),
      ]) == TrackpadGestures.Listening(taps: [], holds: [], corners: [.bottomLeft, .topRight]))
  }

  /// 打字时手掌搭着触控板会被认成四指长按（2026-11-28 真机探针）：最近 1 秒按过键就不认长按
  @Test func holdsAreIgnoredWhileTyping() {
    #expect(TrackpadGestures.isTyping(secondsSinceKey: 0.2))
    #expect(TrackpadGestures.isTyping(secondsSinceKey: 0.99))
    #expect(!TrackpadGestures.isTyping(secondsSinceKey: 1.5))
    #expect(!TrackpadGestures.isTyping(secondsSinceKey: .infinity))
  }

  /// 按 App 停用跟着快捷键页（拍板 B7）：动作看那一条停没停它，启动器命令只跟「全部」
  @Test func blockedTargetsFollowTheShortcutsPage() {
    let clipboard = TrackpadGestureTarget.action(.clipboard)
    let command = TrackpadGestureTarget.command("system:lock")
    #expect(!clipboard.isBlocked(by: nil))
    #expect(!command.isBlocked(by: nil))
    #expect(clipboard.isBlocked(by: .all))
    #expect(command.isBlocked(by: .all))
    #expect(clipboard.isBlocked(by: .only([.clipboard])))
    #expect(!TrackpadGestureTarget.action(.launcher).isBlocked(by: .only([.clipboard])))
    #expect(!command.isBlocked(by: .only([.clipboard])))
  }

  /// 系统的三指手势（拍板 B6）：两个域里有一个是「三指轻点 = 查询」（2）/ 开着三指拖移就算；只读
  @Test func systemThreeFingerGesturesAreRead() throws {
    let names = (0..<2).map { _ in "kitty-test-\(UUID().uuidString)" }
    let builtIn = try #require(UserDefaults(suiteName: names[0]))
    let magic = try #require(UserDefaults(suiteName: names[1]))
    defer { for name in names { UserDefaults.standard.removePersistentDomain(forName: name) } }
    #expect(TrackpadSystemConflicts.read([builtIn, magic]) == TrackpadSystemConflicts())
    builtIn.set(0, forKey: TrackpadSystemConflicts.lookUpKey)
    magic.set(2, forKey: TrackpadSystemConflicts.lookUpKey)
    #expect(TrackpadSystemConflicts.read([builtIn, magic]) == .init(lookUp: true, drag: false))
    #expect(TrackpadSystemConflicts.read([builtIn]) == TrackpadSystemConflicts())
    builtIn.set(true, forKey: TrackpadSystemConflicts.dragKey)
    #expect(TrackpadSystemConflicts.read([builtIn]) == .init(lookUp: false, drag: true))
  }

  /// G1：框架是在它自己的线程上交帧的。在后台线程上经插件真正用的收帧闭包喂一下四指轻点、一下没绑的三指轻点、左下角和
  /// 没绑的右上角各一下，不能 trap；只有绑了的那几种交到 onEvent
  @Test func trackerRunsOnABackgroundThread() async {
    let box = EventBox()
    let consumer = TrackpadGestures.consumer(
      feeding: GestureTracker(taps: [4], holds: [], corners: [.bottomLeft], onEvent: box.onEvent))
    let four = Self.fingers(4)
    let bottomLeft = Self.finger(0.02, 0.03)
    let topRight = Self.finger(0.98, 0.97)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        consumer(1, TouchFrame(time: 1, touches: four))
        consumer(1, TouchFrame(time: 1.1, touches: []))
        consumer(1, TouchFrame(time: 2, touches: Array(four.prefix(3))))
        consumer(1, TouchFrame(time: 2.1, touches: []))
        consumer(1, TouchFrame(time: 3, touches: bottomLeft))
        consumer(1, TouchFrame(time: 3.1, touches: []))
        consumer(1, TouchFrame(time: 4, touches: topRight))
        consumer(1, TouchFrame(time: 4.1, touches: []))
        continuation.resume()
      }
    }
    #expect(box.events.withLock { $0 } == [.tap(fingers: 4), .corner(.bottomLeft)])
  }
}

/// 在（后台的）框架线程上记下交出来的那几下（Mutex 不能直接被逃逸闭包捕获，包一层；闭包在 nonisolated 的上下文里建，G1）
nonisolated private final class EventBox: Sendable {
  let events = Mutex<[FingerGesture.Event]>([])

  var onEvent: @Sendable (UInt, FingerGesture.Event, Double) -> Void {
    { [self] _, event, _ in events.withLock { $0.append(event) } }
  }
}
