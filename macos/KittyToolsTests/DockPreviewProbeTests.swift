// 程序坞预览的本机探针（第九族第 1 批；按需开，默认跳过）：`TEST_RUNNER_KITTY_DOCK_PROBE=1` 才跑。只读、不动屏幕：
//   - 两项授权、WindowServer 的私有接口哪些不在；
//   - 程序坞的辅助功能结构（列表、各种子角色的图标各几个、App 图标带不带 AXURL）、观察者挂不挂得上；
//   - 每个开着的普通 App 列窗口要多久、各种状态各几扇，每扇在哪个桌面；
//   - 截缩略图（WindowServer 1x 截 + 缩小）每扇要多久；私有接口截出来的原图是有内容、全透明还是没截到（按窗口状态记，
//     看最小化的窗口是哪一种）。
// 不切窗口、不关窗口、不挪鼠标（停到图标上发不发通知要真机手测）。数字打进日志，grep「dock-probe」看；测试宿主是 Dev 版，
// 它有没有辅助功能 / 屏幕录制授权就决定能量到什么。

import AppKit
import Testing

@testable import KittyTools

@MainActor
struct DockPreviewProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_DOCK_PROBE"] == "1"
  }

  private func say(_ line: String) { print("dock-probe \(line)") }

  @Test(.enabled(if: DockPreviewProbeTests.isEnabled)) func measure() async throws {
    say(
      "授权：辅助功能 \(Permissions.isAccessibilityTrusted) 屏幕录制 \(Permissions.isScreenRecordingAllowed)")
    say(
      "私有接口不在的：\(WindowServer.missing.isEmpty ? "无" : WindowServer.missing.joined(separator: " "))")

    if let dock = DockWatcher.dockElement() {
      let lists = DockWatcher.lists(of: dock)
      say("程序坞列表 \(lists.count) 个")
      for list in lists {
        let items = DockWatcher.value(list, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var subroles: [String: Int] = [:]
        var withURL = 0
        for item in items {
          let subrole = DockWatcher.value(item, kAXSubroleAttribute) as? String ?? "-"
          subroles[subrole, default: 0] += 1
          if subrole == "AXApplicationDockItem", DockWatcher.value(item, kAXURLAttribute) is URL {
            withURL += 1
          }
        }
        say(
          "  图标 \(items.count)：\(subroles.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))；App 图标带 AXURL 的 \(withURL)"
        )
        let selected = DockWatcher.value(list, kAXSelectedChildrenAttribute) as? [AXUIElement]
        say("  选中属性读得到 \(selected != nil)（现在选中 \(selected?.count ?? 0) 个）")
        if let first = items.first(where: {
          DockWatcher.value($0, kAXSubroleAttribute) as? String == "AXApplicationDockItem"
        }) {
          let origin = DockWatcher.point(first, kAXPositionAttribute) ?? .zero
          let size = DockWatcher.size(first, kAXSizeAttribute) ?? .zero
          say(
            "  第一个 App 图标「\(DockWatcher.value(first, kAXTitleAttribute) as? String ?? "")」\(origin) \(size)"
          )
        }
      }
      let watcher = DockWatcher()
      say("观察者挂上 \(watcher.start())")
      watcher.stop()
    } else {
      say("拿不到程序坞（没有辅助功能授权，或程序坞没在跑）")
    }

    let lister = DockWindows()
    let shots = WindowShots()
    let box = CGSize(width: 520, height: 280)
    var listTimes: [Double] = []
    var shotTimes: [Double] = []
    var blanks: [String] = []
    var failed: [String] = []
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != getpid()
    }
    for app in apps {
      let start = Date()
      let windows = lister.list(app)
      listTimes.append(Date().timeIntervalSince(start) * 1000)
      guard !windows.isEmpty else { continue }
      var states: [String: Int] = [:]
      for window in windows { states["\(window.state)", default: 0] += 1 }
      say(
        "\(app.localizedName ?? "?")：\(windows.count) 扇 \(states.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))，列用 \(String(format: "%.1f", listTimes.last ?? 0)) ms"
      )
      for window in windows.prefix(4) {
        // 私有接口截出来的原图：分清「全透明」（最小化的窗口可能这样）和「没截到」；shoot 把全透明当没截到
        let raw = WindowServer.capture(window.id)
        let rawState = raw.map { WindowShots.isBlank($0) ? "全透明" : "有内容" } ?? "没截到"
        if raw.map(WindowShots.isBlank) == true {
          blanks.append("\(app.localizedName ?? "?") #\(window.id) \(window.state)")
        }
        let shotStart = Date()
        let image = await shots.shoot(window, maxPixels: box)
        let elapsed = Date().timeIntervalSince(shotStart) * 1000
        if image != nil {
          shotTimes.append(elapsed)
        } else {
          failed.append("\(app.localizedName ?? "?") #\(window.id) \(window.state)")
        }
        say(
          "    #\(window.id) \(window.state) \(Int(window.size.width))×\(Int(window.size.height)) 桌面 \(WindowServer.place(of: window.id).map { "\($0)" } ?? "?") 原图 \(rawState) 缩略图 \(image.map { "\($0.width)×\($0.height)" } ?? "无") \(String(format: "%.1f", elapsed)) ms"
        )
      }
    }
    func summary(_ values: [Double]) -> String {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return "无" }
      return String(
        format: "中位 %.1f ms，最长 %.1f ms（%d 次）", sorted[sorted.count / 2], sorted.last ?? 0,
        sorted.count)
    }
    say("列窗口 \(summary(listTimes))")
    say(
      "截缩略图 \(summary(shotTimes))，原图全透明 \(blanks.count)：\(blanks.joined(separator: "，"))；没截到 \(failed.count)：\(failed.joined(separator: "，"))"
    )
  }
}

/// 面板占多少内存（第 3 批；同一个开关 TEST_RUNNER_KITTY_DOCK_PROBE=1）：屏上量——屏外的窗口系统不画图层，量出来偏小
/// （MemoryProbeTests 文件头第 4 个坑）。面板摆在主屏右上角、透明度 0.02、不接鼠标、不当 key，约两秒；填 14 扇窗口
/// （换成两排）的合成缩略图，量「弹出 → 收起（清内容）→ 放掉整块面板」各阶段的 phys_footprint，做两遍。
/// 同步跑、每阶段包 autoreleasepool、嵌套跑环等画完（同 MemoryProbeTests 的第 2 个坑）
@MainActor
struct DockPreviewMemoryProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_DOCK_PROBE"] == "1"
  }

  private func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
  }

  private func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }

  private func image(_ size: CGSize) -> CGImage? {
    let context = CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)
    context?.setFillColor(NSColor.systemTeal.cgColor)
    context?.fill(CGRect(origin: .zero, size: size))
    return context?.makeImage()
  }

  @Test(.enabled(if: DockPreviewMemoryProbeTests.isEnabled)) func memory() throws {
    let screen = try #require(NSScreen.screens.first)
    let windows = (1...14).map {
      DockWindow(
        id: CGWindowID(900 + $0), title: "文稿 \($0)", state: .shown,
        size: CGSize(width: 1600, height: 1000))
    }
    let base = footprint()
    print(String(format: "dock-probe memory 开始 %.1f MB", base))
    let preview = DockPreview()
    for round in 1...2 {
      var shown = 0.0
      autoreleasepool {
        let panel = preview.makePanel()
        let model = preview.model
        model.appName = "探针"
        model.plan = DockPreviewLayout.plan(
          windows.map(\.size), edge: .bottom, along: 1100, across: 860)
        model.windows = Array(windows.prefix(model.plan.thumbs.count))
        for (window, thumb) in zip(model.windows, model.plan.thumbs) {
          model.images[window.id] = image(
            CGSize(
              width: thumb.width * screen.backingScaleFactor,
              height: thumb.height * screen.backingScaleFactor))
        }
        let size = model.plan.panel
        panel.setFrame(
          NSRect(
            x: screen.frame.maxX - size.width, y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height), display: false)
        panel.alphaValue = 0.02
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        spin(1)
        shown = footprint()
      }
      autoreleasepool {
        preview.hide(animated: false)  // 收起：orderOut + 清内容（面板留着）
        spin(0.5)
      }
      let hidden = footprint()
      autoreleasepool {
        preview.reclaim()  // 空闲回收：缓存 + 收着的面板整块放掉
        spin(0.5)
      }
      let released = footprint()
      print(
        String(
          format:
            "dock-probe memory 第 %d 遍：弹出（%.0f × %.0f 点，%d 张）+%.1f MB → 收起后 +%.1f → 放掉面板后 +%.1f",
          round, preview.model.plan.panel.width, preview.model.plan.panel.height, windows.count,
          shown - base, hidden - base, released - base))
    }
  }
}
