// 提醒的边框（PLAN §10「提醒」C3）：每块屏四条贴边的窄窗口，各一层强调色的渐变（屏幕边上最亮、往里 depth 淡到没有），
// 透明度慢慢呼吸（Whisker 的 ambient「呼吸 1.2 s 往返」，图层动画由渲染服务跑、本进程不逐帧算；减弱动态效果时只亮不呼吸）。
// 不开整屏的透明窗口：整屏的底图要几十 MB（Whisker §8「岛窗口不开全屏透明窗」），四条窄的加起来不到 2 MB。
// 窗口是普通 NSPanel 实例（不子类化）：鼠标点得穿、永不当 key、不进旁白；层级 .statusBar（盖住菜单栏和程序坞；刘海岛在它
// 之后出，所以岛在上面），所有桌面、全屏 App 上都在。刘海岛上同时挂着提醒，「知道了」在岛上点；边框只负责让余光看到。
// 颜色是这一刻的强调色（Style.brand，按窗口的外观取一次：图层创建时取，Whisker §3）。
// 接上 / 拔掉显示器、合上盖子时按现在的屏重摆（screensChanged，第五轮体检 E13）：已有的窄窗口挪过去（呼吸不断），
// 新的屏补四条，没了的屏收掉。补的那几条排在已有的那几条后面（同一层里，岛是后出来的、在它们上面）：拿到最前的话会盖住岛。

import AppKit
import SwiftUI

@MainActor final class ReminderGlow {
  /// 按屏排：每块屏 Edge.allCases 那么多条，顺序同 NSScreen.screens
  private var panels: [NSPanel] = []

  /// 渐变往屏幕里铺多深
  static let depth: CGFloat = 28
  /// 呼吸一个来回的一半（Whisker ambient：1.2 s 往返）
  static let breath: CFTimeInterval = 1.2

  /// 显示着（屏全没了的那一刻窗口是空的，屏回来时照样补上）
  private(set) var isShowing = false

  /// 出来，或者按现在的屏重摆（已经在了也可以再调：挪到的地方不变就什么都不动）
  func show() {
    isShowing = true
    let screens = NSScreen.screens.map(\.frame)
    let edges = Edge.allCases
    while panels.count > screens.count * edges.count { panels.removeLast().orderOut(nil) }
    // 第一次出来时拿到最前（之后挂上的岛在它们上面）；换屏补的排在已有的那条后面
    let existing = panels.first?.windowNumber
    for (index, screen) in screens.enumerated() {
      for (offset, edge) in edges.enumerated() {
        let at = index * edges.count + offset
        if at < panels.count {
          panels[at].setFrame(edge.frame(in: screen, depth: Self.depth), display: true)
          continue
        }
        let strip = Self.strip(edge, on: screen)
        if let existing {
          strip.order(.below, relativeTo: existing)
        } else {
          strip.orderFrontRegardless()
        }
        panels.append(strip)
      }
    }
  }

  /// 屏幕变了（E13）：显示着就按现在的屏重摆
  func screensChanged() {
    if isShowing { show() }
  }

  func dismiss() {
    isShowing = false
    for panel in panels { panel.orderOut(nil) }
    panels = []
  }

  enum Edge: CaseIterable {
    case top, bottom, left, right

    /// 这条窄窗口在屏幕上的位置（屏幕坐标，原点在左下）：上下两条横贯整屏，左右两条竖贯整屏（四个角叠两层，略亮一点）
    func frame(in screen: CGRect, depth: CGFloat) -> CGRect {
      switch self {
      case .top: CGRect(x: screen.minX, y: screen.maxY - depth, width: screen.width, height: depth)
      case .bottom: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: depth)
      case .left: CGRect(x: screen.minX, y: screen.minY, width: depth, height: screen.height)
      case .right:
        CGRect(x: screen.maxX - depth, y: screen.minY, width: depth, height: screen.height)
      }
    }

    /// 渐变从哪亮到哪（图层的单位坐标，原点在左下）：贴着屏幕边的那头最亮
    var points: (start: CGPoint, end: CGPoint) {
      switch self {
      case .top: (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
      case .bottom: (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
      case .left: (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
      case .right: (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
      }
    }
  }

  private static func strip(_ edge: Edge, on screen: CGRect) -> NSPanel {
    let panel = NSPanel(
      contentRect: edge.frame(in: screen, depth: depth),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.setAccessibilityElement(false)

    let gradient = CAGradientLayer()
    var color = CGColor.clear
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
      color = NSColor(Style.brand).cgColor
    }
    gradient.colors = [color.copy(alpha: 0.85) ?? color, color.copy(alpha: 0) ?? color]
    (gradient.startPoint, gradient.endPoint) = edge.points
    let view = NSView()
    view.layer = gradient
    view.wantsLayer = true
    panel.contentView = view

    // 出现：淡入；之后呼吸（减弱动态效果时只亮着）
    gradient.opacity = 1
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = Style.fadeIn
    gradient.add(fade, forKey: "fade")
    if !Style.reduceMotion {
      let breathe = CABasicAnimation(keyPath: "opacity")
      breathe.fromValue = 1
      breathe.toValue = 0.35
      breathe.duration = breath
      breathe.beginTime = CACurrentMediaTime() + Style.fadeIn
      breathe.autoreverses = true
      breathe.repeatCount = .infinity
      breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      gradient.add(breathe, forKey: "breathe")
    }
    return panel
  }
}
