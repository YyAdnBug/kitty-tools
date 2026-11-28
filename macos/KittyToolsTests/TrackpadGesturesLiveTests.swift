// 触控板手势的真机探针（issue #59 第 3 批，按需）：默认跳过，命令行 `TEST_RUNNER_KITTY_LIVE_GESTURES=<目录>` 才跑
// （测试进程里读到的是 KITTY_LIVE_GESTURES，G16）。**会真的订 Touchpad、读这台 Mac 的触控板约 60 秒，跑之前先问用户、要他在场**；
// 只听不拦：不建事件拦截、不发合成输入，鼠标按下 / 抬起只用全局监听看（看不到、也改不了别的 App 收到的事件）。
// 记三样，写进 <目录>/report.md：
// - 插件的识别器认出的每一下（三到五指的轻点、长按；双击是主线程上两下轻点凑的，看时间就知道）；
// - 单指在四个角（各 9%，同 Trackpad Edges）落下、抬起的时刻和挪了多远——拍板 B2「角落」要的数；
// - 系统发给别的 App 的鼠标按下 / 抬起：时刻、压力、阶段、连点数——看「轻点来点按」造出来的那次点按和真按下去的能不能分开。
// 跑的时候照报告开头那张单子做一遍（三到五指各轻点、双击、长按，四指捏合、三指横扫，左下角轻点、双击、按下去点一下）。

import AppKit
import Synchronization
import Testing

@testable import KittyTools

@MainActor
struct TrackpadGesturesLiveTests {
  static let steps = [
    "三指、四指、五指各轻点一下", "三指、四指、五指各双击", "三指、四指、五指各按住一秒", "四指捏合一下、三指左右扫一下（都不该认成轻点）",
    "单指在左下角轻点一下、再双击", "单指在左下角真按下去点一下、再点两下", "两手搭在触控板边上打几个字（不该认成长按）",
  ]

  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_GESTURES"] != nil))
  func recordGestures() async throws {
    let directory = try #require(ProcessInfo.processInfo.environment["KITTY_LIVE_GESTURES"])
    let log = ProbeLog()
    let start = ProcessInfo.processInfo.systemUptime
    let tracker = GestureTracker(
      taps: [3, 4, 5], holds: [3, 4, 5], onEvent: Self.events(into: log))
    Touchpad.shared.subscribe(
      "probe.gestures", consumer: Self.consumer(tracker: tracker, log: log), onReset: {})
    defer { Touchpad.shared.unsubscribe("probe.gestures") }
    let monitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { event in
      // 只读 CGEvent 的字段（NSEvent 的 stage 这类只对压力事件有效）
      let cg = event.cgEvent
      log.add(
        String(
          format: "%.3f mouse %@ pressure %.2f clicks %lld subtype %lld", event.timestamp,
          "\(event.type)", cg?.getDoubleValueField(.mouseEventPressure) ?? -1,
          cg?.getIntegerValueField(.mouseEventClickState) ?? -1,
          cg?.getIntegerValueField(.mouseEventSubtype) ?? -1))
    }
    defer { monitor.map(NSEvent.removeMonitor) }
    print("gesture-probe 开始，60 秒，照 report.md 开头的单子做；availability \(Touchpad.shared.availability)")
    try? await Task.sleep(for: .seconds(60))
    var lines = ["# 触控板手势探针 \(Date())", "", "要做的："] + Self.steps.map { "- \($0)" }
    lines += [
      "",
      "availability: \(Touchpad.shared.availability)，帧数 \(Touchpad.framesSeen)，开始于 uptime \(start)",
      "", "```",
    ]
    lines += log.lines + ["```"]
    let url = URL(fileURLWithPath: directory).appendingPathComponent("report.md")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    print("gesture-probe 写好了 \(url.path)，\(log.lines.count) 行")
    #expect(Touchpad.shared.availability == .available)
  }

  /// 收帧：交给插件的识别器，另外看单指在角落的落下 / 抬起（在框架线程上跑，G1：闭包在 nonisolated 的静态函数里建）
  nonisolated static func consumer(tracker: GestureTracker, log: ProbeLog) -> TouchConsumer {
    let corners = CornerDowns()
    return { device, frame in
      tracker.feed(device: device, frame: frame)
      let touching = frame.touches.filter { $0.state == 3 || $0.state == 4 }
      corners.table.withLock { table in
        if touching.count == 1, let touch = touching.first {
          if var down = table[device] {
            down.far = max(down.far, hypot(touch.x - down.x, touch.y - down.y))
            table[device] = down
          } else if (touch.x <= 0.09 || touch.x >= 0.91) && (touch.y <= 0.09 || touch.y >= 0.91) {
            table[device] = (touch.x, touch.y, frame.time, 0)
            log.add(String(format: "%.3f corner down x %.3f y %.3f", frame.time, touch.x, touch.y))
          }
        } else if let down = table.removeValue(forKey: device) {
          log.add(
            String(
              format: "%.3f corner up after %.3f s, moved %.3f, fingers now %d", frame.time,
              frame.time - down.time, down.far, touching.count))
        }
      }
    }
  }

  nonisolated static func events(into log: ProbeLog)
    -> @Sendable (
      UInt, FingerGesture.Event, Double
    ) -> Void
  {
    { device, event, time in
      log.add(String(format: "%.3f gesture %@ device %lu", time, "\(event)", device))
    }
  }
}

/// 单指在角落落下的那一下（Mutex 不能被逃逸闭包直接捕获，包一层）
nonisolated final class CornerDowns: Sendable {
  let table = Mutex<[UInt: (x: Double, y: Double, time: Double, far: Double)]>([:])
}

/// 几条线程上一起记（框架线程、主线程）
nonisolated final class ProbeLog: Sendable {
  private let storage = Mutex<[String]>([])
  var lines: [String] { storage.withLock { $0 } }
  func add(_ line: String) { storage.withLock { $0.append(line) } }
}
