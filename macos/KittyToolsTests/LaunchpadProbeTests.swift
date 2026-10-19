// 启动台的性能 / 内存探针（第八族，R11；按需开，默认跳过）：`TEST_RUNNER_KITTY_LAUNCHPAD_PROBE=1` 才跑。
// 量的都是屏外的东西（不启动 App、不建真面板、不 makeKey），数字打进日志，grep「launchpad-probe」看：
//   - 扫一遍本机 App 目录（LaunchpadCatalog.load）多久；
//   - 屏外把界面建出来、量到网格框（第一帧）多久；
//   - 翻一页之后主线程做一次布局要多久（中位 / 最长）；
//   - 两指滑跟手时每一帧（喂一次 scroll 再布局一次）主线程要多久（中位 / 最长）；
//   - 捏合跟手时每一帧（改一次 model.zoom 再布局一次：上面那层的缩放，GESTURE.md A）主线程要多久（中位 / 最长）；
//   - 建出来、收起放掉前后 phys_footprint 各多少（活动监视器的口径）。
// 触控板监听静置时的 CPU 量不了：R11 要求只在真机上量（单测里不注册回调、不读真触点，SPEC §2），
// 数字在 HANDTEST「启动台手测」10 里看。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadProbeTests {
  nonisolated private static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["KITTY_LAUNCHPAD_PROBE"] == "1"
  }

  private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
  }

  @Test(.enabled(if: LaunchpadProbeTests.isEnabled)) func measure() throws {
    let megabyte = 1024 * 1024
    let scanStart = Date()
    let catalog = LaunchpadCatalog.load()
    let scan = Date().timeIntervalSince(scanStart)
    let layout = LaunchpadLayout.defaultLayout(
      catalog.map {
        LaunchpadLayout.DefaultApp(
          ref: $0.ref, name: $0.name, isSystem: $0.isSystem, inUtilities: $0.inUtilities)
      }, capacity: 35)
    let size = NSSize(width: 1600, height: 1000)
    let before = footprint()
    var opened = 0
    var median = 0.0
    var worst = 0.0
    var firstFrame = 0.0
    var trackMedian = 0.0
    var trackWorst = 0.0
    var zoomMedian = 0.0
    var zoomWorst = 0.0
    do {
      let model = LaunchpadModel(
        layout: layout, catalog: catalog, icons: LaunchpadIcons(), columns: 7, rows: 5,
        screenSize: size)
      let host = NSHostingView(
        rootView: LaunchpadView(model: model).frame(width: size.width, height: size.height))
      let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      let firstFrameStart = Date()
      window.orderFront(nil)
      var waited = 0.0
      while model.gridFrames[0] == nil, waited < 2 {
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.005))
        waited += 0.005
      }
      firstFrame = Date().timeIntervalSince(firstFrameStart)
      opened = footprint()
      // 翻页：每翻一页量一次主线程的布局
      var layoutTimes: [Double] = []
      for index in 0..<20 {
        model.go(to: index % max(model.pageCount, 1))
        let start = Date()
        host.layoutSubtreeIfNeeded()
        layoutTimes.append(Date().timeIntervalSince(start))
      }
      layoutTimes.sort()
      median = layoutTimes[layoutTimes.count / 2] * 1000
      worst = (layoutTimes.last ?? 0) * 1000
      // 跟手：回到第一页、等动画走完，再一帧帧往左滑（每帧 8 pt、16 ms），每帧量一次布局
      model.go(to: 0)
      RunLoop.main.run(until: Date.now.addingTimeInterval(0.6))
      host.layoutSubtreeIfNeeded()
      var trackTimes: [Double] = []
      let t0 = ProcessInfo.processInfo.systemUptime
      model.scroll(deltaX: 0, deltaY: 0, precise: true, phase: .began, momentum: [], time: t0)
      for frame in 1...60 {
        model.scroll(
          deltaX: -8, deltaY: 0, precise: true, phase: .changed, momentum: [],
          time: t0 + Double(frame) * 0.016)
        let start = Date()
        host.layoutSubtreeIfNeeded()
        trackTimes.append(Date().timeIntervalSince(start))
      }
      trackTimes.sort()
      trackMedian = trackTimes[trackTimes.count / 2] * 1000
      trackWorst = (trackTimes.last ?? 0) * 1000
      // 捏合跟手：zoom 从 0 走到 1（60 帧），每帧量一次布局
      var zoomTimes: [Double] = []
      for frame in 0...60 {
        model.zoom = Double(frame) / 60
        let start = Date()
        host.layoutSubtreeIfNeeded()
        zoomTimes.append(Date().timeIntervalSince(start))
      }
      zoomTimes.sort()
      zoomMedian = zoomTimes[zoomTimes.count / 2] * 1000
      zoomWorst = (zoomTimes.last ?? 0) * 1000
      window.orderOut(nil)
      window.contentView = nil
    }
    // 让窗口 / 图层的资源先收走，再让分配器把空页还回去
    RunLoop.main.run(until: Date.now.addingTimeInterval(0.3))
    Memory.relieve()
    let released = footprint()
    let count = catalog.count
    print(
      String(
        format:
          "launchpad-probe apps=%d scan=%.1fms firstFrame=%.1fms pageLayout median=%.2fms worst=%.2fms track median=%.2fms worst=%.2fms zoom median=%.2fms worst=%.2fms footprint open=+%.1fMB released=%+.1fMB",
        count, scan * 1000, firstFrame * 1000, median, worst, trackMedian, trackWorst,
        zoomMedian, zoomWorst,
        Double(opened - before) / Double(megabyte), Double(released - before) / Double(megabyte)))
  }
}
