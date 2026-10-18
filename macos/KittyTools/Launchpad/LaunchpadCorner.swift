// 触发角（SPEC §5.7，R8）：设置里选一个屏幕角（默认关），鼠标推到那个角停约 0.3 秒就打开启动台。
// 照便签边缘药丸（Notes/NoteDeckPill.swift）的路数：每块屏在那个角放一个几个点大的**普通 NSPanel 实例**
// （不子类化，不是浮层）：层级 .statusBar（和菜单栏同层，顶上两个角不会被菜单栏盖住，F15）、所有桌面和全屏里都能出、
// `sharingType = .none` 不进截图录屏、用追踪区感应进入——**不挂全局鼠标监听、不轮询**。
// 整块几乎透明（alpha 0.01，不是 0）：完全透明的窗口可能被系统点穿，追踪区就收不到进出；这一层底色是 paint 用的。
// 停够时间才触发；触发后要等一次真的 mouseExited 才重新武装（收起时鼠标还在角里不会马上再开）。
// 只读 com.apple.dock 的 wvous-*-corner：用户在那个角也设了系统动作时不抢（设置页提示一句）。
// 截图 / 录屏 / 状态屏时不响应（由 Launchpad 的 canOpen 拦）。

import AppKit

/// 设置里的四个角（+ 关）
nonisolated enum LaunchpadCornerOption: String, CaseIterable, Identifiable {
  case off, topLeft, topRight, bottomLeft, bottomRight

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: "关"
    case .topLeft: "左上角"
    case .topRight: "右上角"
    case .bottomLeft: "左下角"
    case .bottomRight: "右下角"
    }
  }

  /// 角在屏里的位置（visibleFrame 的口径；nil = 关）
  func origin(in frame: CGRect, size: CGFloat) -> CGPoint? {
    switch self {
    case .off: nil
    case .topLeft: CGPoint(x: frame.minX, y: frame.maxY - size)
    case .topRight: CGPoint(x: frame.maxX - size, y: frame.maxY - size)
    case .bottomLeft: CGPoint(x: frame.minX, y: frame.minY)
    case .bottomRight: CGPoint(x: frame.maxX - size, y: frame.minY)
    }
  }
}

@MainActor
final class LaunchpadCorner {
  /// 鼠标在角里停够了
  var onTrigger: (() -> Void)?
  /// 停多久算（约 0.3 秒）
  static let dwell: Duration = .milliseconds(300)
  /// 那个角上系统的触发角动作（Dock 的 wvous-*-corner；0 和 1 都是没设——在系统设置里选「—」写的是 1，G7）
  nonisolated static let systemCornerKeys: [LaunchpadCornerOption: String] = [
    .topLeft: "wvous-tl-corner", .topRight: "wvous-tr-corner",
    .bottomLeft: "wvous-bl-corner", .bottomRight: "wvous-br-corner",
  ]

  /// 这个角也让系统触发角占了没有（纯函数：单测直接喂 Dock 的那份偏好；只读）
  nonisolated static func systemCornerIsOn(
    _ option: LaunchpadCornerOption, dock: [String: Any]?
  ) -> Bool {
    guard let key = systemCornerKeys[option] else { return false }
    return (dock?[key] as? Int ?? 0) > 1
  }

  /// 本机读 Dock 的偏好
  nonisolated static func systemCornerIsOn(
    _ option: LaunchpadCornerOption, defaults: UserDefaults = .standard
  ) -> Bool {
    systemCornerIsOn(option, dock: defaults.persistentDomain(forName: "com.apple.dock"))
  }
  /// 感应窗口多大（点）。鼠标推到角上时就停在角上那一个像素，几个点就够；
  /// 越大越会吞掉角上的点击（左上角那块是苹果菜单，G6）
  static let size: CGFloat = 4
  /// 启动台现在开着没有：开着时全屏面板盖住了角，那时的「离开」不算真离开（G7）
  var isLaunchpadOpen: () -> Bool = { false }

  private var panels: [NSPanel] = []
  private var dwellTask: Task<Void, Never>?
  private var option: LaunchpadCornerOption = .off
  /// 触发了以后要等鼠标离开角才重新武装（F15）
  private var arm = CornerArm()

  /// 按设置摆好：关着就全收掉；换角 / 换屏重新摆
  func apply(option: LaunchpadCornerOption, screens: [NSScreen]) {
    self.option = option
    dwellTask?.cancel()
    dwellTask = nil
    guard option != .off else {
      stop()
      return
    }
    // 那个角也设了系统触发角：不抢，设置页会提示（F15）
    guard !Self.systemCornerIsOn(option) else {
      stop()
      return
    }
    // 屏数 / 分辨率变了就重建（数量对不上时）
    if panels.count != screens.count {
      stop()
      for screen in screens {
        guard let origin = option.origin(in: screen.frame, size: Self.size) else { continue }
        let panel = makePanel(
          frame: CGRect(origin: origin, size: CGSize(width: Self.size, height: Self.size)))
        panels.append(panel)
      }
    } else {
      for (panel, screen) in zip(panels, screens) {
        guard let origin = option.origin(in: screen.frame, size: Self.size) else { continue }
        panel.setFrame(
          CGRect(origin: origin, size: CGSize(width: Self.size, height: Self.size)), display: false)
      }
    }
    for panel in panels where !panel.isVisible { panel.orderFrontRegardless() }
    // 不复位武装：设置页、换屏一调就复位的话，刚触发过、鼠标还在角里时又会再开一次（G7）
  }

  func stop() {
    dwellTask?.cancel()
    dwellTask = nil
    for panel in panels {
      panel.orderOut(nil)
      panel.contentView = nil
    }
    panels = []
  }

  private func makePanel(frame: CGRect) -> NSPanel {
    let panel = Self.makeSensorPanel(frame: frame)
    let host = CornerHost(frame: CGRect(origin: .zero, size: frame.size))
    host.onEnter = { [weak self] in self?.enter() }
    host.onExit = { [weak self] in self?.exit() }
    panel.contentView = host
    return panel
  }

  /// 感应窗口本身（单测直接建，不摆上屏）：真画一层 1% 的底色——整块透明的窗口会被系统点穿，追踪区收不到进出（G6）。
  /// 窗口自己的 alpha 留 1：原来设 `alphaValue = 0.01`、底色却是 clear，里面一个像素都没有，等于没画
  static func makeSensorPanel(frame: CGRect) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    // .statusBar：和菜单栏同层，顶上两个角不会被菜单栏盖住（F15）
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = false
    // 不参与截图 / 录屏（F15；和浮层面板同一套排除手法）
    panel.sharingType = .none
    return panel
  }

  private func enter() {
    guard arm.armed, dwellTask == nil else { return }
    dwellTask = Task { [weak self] in
      try? await Task.sleep(for: LaunchpadCorner.dwell)
      guard !Task.isCancelled, let self else { return }
      dwellTask = nil
      guard arm.trigger() else { return }
      onTrigger?()
    }
  }

  private func exit() {
    dwellTask?.cancel()
    dwellTask = nil
    arm.mouseExited(launchpadOpen: isLaunchpadOpen())
  }
}

/// 触发后要真的离开角才重新武装（F15）：进、停够、触发一次；不离开再进不再触发。
nonisolated struct CornerArm: Equatable {
  private(set) var armed = true

  /// 停够了：第一次返回 true 并上锁，之后到 `mouseExited` 之前都 false
  mutating func trigger() -> Bool {
    guard armed else { return false }
    armed = false
    return true
  }

  /// 鼠标离开了角：启动台开着时（全屏面板盖住了角，离开 / 进来都是面板引起的）不算，收起后真离开才重新武装（G7）
  mutating func mouseExited(launchpadOpen: Bool = false) {
    if !launchpadOpen { armed = true }
  }
}

/// 感应窗口的内容：一块透明的视图，进出时报一声（追踪区 activeAlways，本 App 不在前台也收得到）
private final class CornerHost: NSView {
  var onEnter: () -> Void = {}
  var onExit: () -> Void = {}
  private var area: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    area.map(removeTrackingArea)
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    self.area = area
  }

  override func mouseEntered(with event: NSEvent) { onEnter() }
  override func mouseExited(with event: NSEvent) { onExit() }
  override func draw(_ dirtyRect: NSRect) {}
}
