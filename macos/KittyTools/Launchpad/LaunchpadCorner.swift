// 触发角（SPEC §5.7，R8）：设置里选一个屏幕角（默认关），鼠标推到那个角停约 0.3 秒就打开启动台。
// 照便签边缘药丸（Notes/NoteDeckPill.swift）的路数：每块屏在那个角放一个几个点大的**普通 NSPanel 实例**
// （不子类化，不是浮层）：只用图层画（其实什么都不画，透明）、层级 floating、所有桌面和全屏里都能出、
// 不进截图录屏（装饰）、用追踪区感应进入——**不挂全局鼠标监听、不轮询**。
// 停够时间才触发；中途离开或系统触发角先动了鼠标就取消。截图 / 录屏 / 状态屏时不响应（由 Launchpad 的 canOpen 拦）。

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
  /// 感应窗口多大（点）
  static let size: CGFloat = 6

  private var panels: [NSPanel] = []
  private var dwellTask: Task<Void, Never>?
  private var option: LaunchpadCornerOption = .off

  /// 按设置摆好：关着就全收掉；换角 / 换屏重新摆
  func apply(option: LaunchpadCornerOption, screens: [NSScreen]) {
    self.option = option
    dwellTask?.cancel()
    dwellTask = nil
    guard option != .off else {
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
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.ignoresMouseEvents = false
    let host = CornerHost(frame: CGRect(origin: .zero, size: frame.size))
    host.onEnter = { [weak self] in self?.enter() }
    host.onExit = { [weak self] in self?.exit() }
    panel.contentView = host
    return panel
  }

  private func enter() {
    guard dwellTask == nil else { return }
    dwellTask = Task { [weak self] in
      try? await Task.sleep(for: LaunchpadCorner.dwell)
      guard !Task.isCancelled, let self else { return }
      dwellTask = nil
      onTrigger?()
    }
  }

  private func exit() {
    dwellTask?.cancel()
    dwellTask = nil
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
