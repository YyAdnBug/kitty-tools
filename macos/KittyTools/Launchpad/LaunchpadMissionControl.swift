// 调度中心开着时打开启动台：先让调度中心退掉（2026-10-19 真机反馈：调度中心给窗口画的 ✕ 盖在启动台上面，而且还点得到——
// 它不是普通窗口，层级调高也盖不住）。原版启动台是程序坞自己管的，从调度中心捏合打开时调度中心本来就退了。
// 认法：macOS 27 起总览（调度中心、App Exposé）归 WindowManager，开着时有一块整屏大小、19 层的窗口（Space Rabbit 的源码注释；
// 本机 27.0.1 实测进出调度中心都对）。退法：打开系统的「调度中心」App（开着时再打开 = 退出，不激活它；实测 0.35–0.5 s 退干净）。
// **退干净之前启动台可以先出来，但不能 makeKey**（总控 `waitForMissionControl` 等着再拿键盘）：退场中途面板 makeKey，
// WindowManager 的窗口排序会乱，之后某个应用的窗口一直压在最上面（2026-10-19 真机两次，要 killall WindowManager 才好）。
// 只读窗口表，不要授权。探针在 build/research/launchpad/probe/（mc-focus/test.swift 分开试过：光让它退、等退干净再盖面板、
// 马上盖但退干净再 makeKey，都不乱）。
// ponytail: 只认 macOS 27 的 WindowManager 19 层。26 上总览归程序坞（整屏 18 层），可那一层「显示桌面」时也有，认错了会反过来
// 把调度中心打开，没 26 的机器验就先不认（26 上还是旧问题）；App Exposé 也是 19 层，打开「调度中心」App 能不能退掉没验。

import AppKit
import CoreGraphics

nonisolated enum LaunchpadMissionControl {
  /// 窗口表里看的那几样
  struct Window: Equatable {
    var owner: String
    var layer: Int
    var size: CGSize
  }

  /// 调度中心开着没有（纯函数，单测）：macOS 27 起 WindowManager 有一块和某块屏一样大的 19 层窗口
  static func isActive(windows: [Window], displays: [CGSize], majorVersion: Int) -> Bool {
    guard majorVersion >= 27 else { return false }
    return windows.contains { window in
      window.owner == "WindowManager" && window.layer == 19
        && displays.contains {
          abs($0.width - window.size.width) <= 1 && abs($0.height - window.size.height) <= 1
        }
    }
  }

  /// 读这台机器现在的窗口表（屏上的，几毫秒）
  static func isActive() -> Bool {
    let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard majorVersion >= 27,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let windows = list.compactMap { info -> Window? in
      guard let owner = info[kCGWindowOwnerName as String] as? String,
        let layer = info[kCGWindowLayer as String] as? Int,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds)
      else { return nil }
      return Window(owner: owner, layer: layer, size: rect.size)
    }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
    let displays = ids.prefix(Int(count)).map { CGDisplayBounds($0).size }
    return isActive(windows: windows, displays: displays, majorVersion: majorVersion)
  }

  /// 让它退：打开系统的「调度中心」App（开着时再打开 = 退出）。不激活它
  @MainActor
  static func dismiss() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
      configuration: configuration)
  }
}
