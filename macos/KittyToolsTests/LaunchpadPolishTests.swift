// 启动台 2026-10-19 真机反馈那一轮的单测：触控板手势选四指 / 五指、翻页松手接着手指的速度走、点搜索框要有反应。
// 不注册触控板回调、不 makeKey、不发系统事件（面板在屏外建）。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

@MainActor
struct LaunchpadPolishTests {
  private func frame(_ time: Double, _ points: [(Double, Double)]) -> TouchFrame {
    TouchFrame(
      time: time,
      touches: points.enumerated().map { index, point in
        TouchPoint(id: Int32(index), x: point.0, y: point.1, state: 4)
      })
  }

  /// 五个点围着 (0.5, 0.5)，半径 r
  private func five(_ r: Double) -> [(Double, Double)] {
    (0..<5).map { index in
      let angle = Double(index) * 2 * .pi / 5
      return (0.5 + r * cos(angle), 0.5 + r * sin(angle))
    }
  }

  private func four(_ r: Double) -> [(Double, Double)] {
    [(0.5 - r, 0.5), (0.5, 0.5 - r), (0.5 + r, 0.5), (0.5, 0.5 + r)]
  }

  // MARK: 四指 / 五指

  @Test func fiveFingerModeOnlyCountsFiveFingers() {
    var recognizer = PinchRecognizer(sensitivity: .standard, fingers: .five)
    // 四指捏：不认
    #expect(recognizer.feed(frame(0, four(0.2))) == nil)
    #expect(recognizer.feed(frame(0.2, four(0.12))) == nil)
    #expect(recognizer.feed(frame(0.3, [])) == nil)
    // 五指捏：认
    #expect(recognizer.feed(frame(0.4, five(0.2))) == nil)
    #expect(recognizer.feed(frame(0.6, five(0.12))) == .pinch)
  }

  @Test func fourFingerModeIgnoresFiveFingers() {
    var recognizer = PinchRecognizer(sensitivity: .standard, fingers: .four)
    #expect(recognizer.feed(frame(0, five(0.2))) == nil)
    #expect(recognizer.feed(frame(0.2, five(0.12))) == nil)
    #expect(recognizer.feed(frame(0.3, [])) == nil)
    #expect(recognizer.feed(frame(0.4, four(0.2))) == nil)
    #expect(recognizer.feed(frame(0.6, four(0.12))) == .pinch)
  }

  @Test func fingerChoicesAcceptTheRightCounts() {
    #expect(!PinchFingers.off.accepts(4) && !PinchFingers.off.accepts(5))
    #expect(PinchFingers.four.accepts(4) && !PinchFingers.four.accepts(3))
    #expect(!PinchFingers.four.accepts(5))
    #expect(PinchFingers.five.accepts(5) && PinchFingers.five.accepts(6))
    #expect(!PinchFingers.five.accepts(4))
    // 设置页的三档按这个顺序排
    #expect(PinchFingers.allCases.map(\.title) == ["关闭", "四指捏合", "五指捏合"])
  }

  // MARK: 翻页松手的速度

  /// 手指的速度按这次要走的距离归一（正 = 朝目标走），限在 ±ω 以内（临界阻尼超过 ω 会冲过头）
  @Test func releaseVelocityIsNormalizedAndClamped() {
    let omega = 2 * Double.pi / LaunchpadPager.spring.duration
    // 往左甩 1200 pt/s、还要往左走 1000 pt：朝目标 1.2
    #expect(abs(LaunchpadPager.initialVelocity(velocity: -1200, distance: -1000) - 1.2) < 1e-9)
    // 还在往左、但要弹回右边：背着目标，负的
    #expect(LaunchpadPager.initialVelocity(velocity: -200, distance: 100) < 0)
    // 快到了还很快：限住，不冲过头
    #expect(LaunchpadPager.initialVelocity(velocity: -5000, distance: -10) == omega)
    #expect(LaunchpadPager.initialVelocity(velocity: 5000, distance: -10) == -omega)
    // 几乎不用走：不给初速度
    #expect(LaunchpadPager.initialVelocity(velocity: 3000, distance: 0.5) == 0)
  }

  /// 松手那一刻的速度：一直在动就是最后几帧的速度，手指停住再抬起来算 0
  @Test func releaseVelocityDropsToZeroAfterAPause() {
    var pager = LaunchpadPager()
    for index in 0...5 {
      _ = pager.feed(
        delta: -20, time: 10 + Double(index) * 0.01, pageWidth: 900, canBack: true,
        canForward: true)
    }
    #expect(pager.releaseVelocity(time: 10.055) < -1000)
    #expect(pager.screenVelocity(time: 10.055) == pager.releaseVelocity(time: 10.055))
    #expect(pager.releaseVelocity(time: 10.3) == 0)
  }

  /// 第一页往右拉（橡皮筋）：屏上只走手指的 0.18 倍，弹回来的初速度也按这个算
  @Test func rubberBandReleaseUsesTheDampedSpeed() {
    var pager = LaunchpadPager()
    for index in 0...5 {
      _ = pager.feed(
        delta: 20, time: 10 + Double(index) * 0.01, pageWidth: 900, canBack: false,
        canForward: true)
    }
    let finger = pager.releaseVelocity(time: 10.055)
    #expect(finger > 1000)
    #expect(abs(pager.screenVelocity(time: 10.055) - finger * LaunchpadPager.resistance) < 1e-6)
  }

  // MARK: 点搜索框

  private func model() -> LaunchpadModel {
    let refs = ["a", "b"].map {
      LaunchpadAppRef(bundleID: "com.example.\($0)", path: "/Applications/\($0).app")
    }
    let folder = LaunchpadFolder(name: "X", pages: [refs])
    let catalog = refs.map { ref in
      let name = ref.bundleID ?? ref.path
      return LaunchpadProjectApp(
        id: ref.id, ref: ref,
        item: LauncherItem(
          kind: .app, target: ref.path, title: name, subtitle: "应用程序",
          names: [LauncherMatch.fold(name)], initials: [LauncherMatch.initials(name)]),
        url: URL(filePath: ref.path), isSystem: false, inUtilities: false, isAppStore: false,
        category: nil)
    }
    return LaunchpadModel(
      layout: LaunchpadLayout(pages: [[.folder(folder)]]), catalog: catalog,
      icons: LaunchpadIcons(), columns: 7, rows: 5, screenSize: CGSize(width: 900, height: 600),
      dragTiming: .immediate)
  }

  /// 点一下：占位挪到左边（亮插入点）；交出焦点（开文件夹、进抖动）时回到正中；打过字也算点过
  @Test func clickingTheSearchFieldEngagesIt() throws {
    let model = model()
    #expect(!model.searchEngaged)
    model.searchClicked()
    #expect(model.searchEngaged)
    let folder = try #require(model.layout.pages.first?.first?.folder)
    model.openFolder(folder.id)
    #expect(!model.searchEngaged)
    model.closeFolder()
    model.searchClicked()
    model.enterJiggle()
    #expect(!model.searchEngaged)
    model.exitJiggle()
    model.query = "a"
    #expect(model.searchEngaged)
    // 有字的时候进抖动：字还在，占位不回正中
    model.enterJiggle()
    #expect(model.searchEngaged)
  }

  /// 面板按点在哪判断是不是点在搜索框上（屏外面板，不当 key、不发事件）
  @Test func panelKnowsWhenAClickLandsOnTheSearchField() async throws {
    let model = model()
    let panel = LaunchpadPanel(
      frame: NSRect(x: -20000, y: -20000, width: 900, height: 600), model: model)
    panel.orderFront(nil)
    defer { panel.orderOut(nil) }
    // 界面刚挂上时 initialFirstResponder 先是整个界面视图，等搜索框建出来登记上
    for _ in 0..<40 where !(panel.initialFirstResponder is NSTextField) {
      try await Task.sleep(for: .milliseconds(50))
    }
    let field = try #require(panel.initialFirstResponder as? NSTextField)
    let center = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
    #expect(panel.hitsSearchField(center))
    // 框下面的空白（背景）不算
    #expect(!panel.hitsSearchField(NSPoint(x: center.x, y: center.y - 200)))
    #expect(!panel.isKeyWindow)
  }
}
