// 刘海岛（Whisker 招牌时刻 S2，mac-whisker §5）：全局轻提示从刘海里长出来；没有刘海的屏幕上是菜单栏下方的黑色胶囊。
// 一个尺寸固定、不接鼠标、不抢键盘的透明窗口（普通 NSPanel 实例，level 状态栏）放在鼠标所在屏顶部正中，
// 只让 SwiftUI 里的岛形状变形，不动画窗口 frame。内容晚 60 ms 出场；原地更新（翻译中 → 已替换）只换宽度；
// 错误时整座岛左右抖一下；消失时先退内容，再缩回刘海。停留：只有标题 1.4 s、带详情 2 s、错误 3 s、进行中一直挂着。

import AppKit
import Observation
import SwiftUI

@Observable final class Island {
  enum Tone {
    case success, info, warning, error
    /// 进行中：一直挂着，直到下一条替换它（60 s 兜底）
    case progress
  }

  /// 前导位置：按语气出符号，或者取色的色块、截图的缩略图
  enum Leading: Equatable {
    case tone
    case color(NSColor)
    case thumbnail(NSImage)
  }

  struct Content: Equatable {
    var title: String
    var detail: String?
    var tone: Tone
    var symbol: String
    var leading: Leading
  }

  /// 正在显示的内容；nil = 内容已退场（形体可能还在缩回）
  private(set) var content: Content?
  /// 形体展开着
  private(set) var isOpen = false
  /// 每次出错 +1，触发抖动
  private(set) var shakes = 0
  @ObservationIgnored private(set) var geometry = Geometry.capsule(menuBar: 24)
  @ObservationIgnored private var window: NSPanel?
  @ObservationIgnored private var dwell: Task<Void, Never>?

  /// 刘海屏：从刘海长出下巴；其它屏：菜单栏下方的胶囊
  enum Geometry: Equatable {
    case notch(width: CGFloat, height: CGFloat)
    case capsule(menuBar: CGFloat)

    /// 窗口尺寸：最宽 460 的岛 + 两侧耳朵与阴影余量
    var windowSize: CGSize {
      switch self {
      case .notch(_, let height): CGSize(width: 520, height: height + Island.chin + 26)
      case .capsule: CGSize(width: 520, height: Island.chin + 34)
      }
    }
  }

  /// showing：截图自检直接摆出展开的样子（不建窗口）；正常使用就是 `Island()`
  init(showing content: Content? = nil, geometry: Geometry = .capsule(menuBar: 24)) {
    self.content = content
    isOpen = content != nil
    self.geometry = geometry
  }

  /// 下巴 / 胶囊高度
  static let chin: CGFloat = 36
  static let maxWidth: CGFloat = 460

  func show(
    _ title: String, detail: String? = nil, tone: Tone = .success, symbol: String? = nil,
    leading: Leading = .tone
  ) {
    let next = Content(
      title: title, detail: detail, tone: tone, symbol: symbol ?? Self.symbol(for: tone),
      leading: leading)
    dwell?.cancel()
    if isOpen, content != nil {
      // 原地更新：内容交叉模糊替换，宽度跟着内容走（spring 0.32）
      withAnimation(
        Style.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.15)
      ) {
        content = next
      }
    } else {
      open(with: next)
    }
    if tone == .error { shakes += 1 }
    announce(next)
    let seconds: Double =
      switch tone {
      case .progress: 60
      case .error: 3
      default: detail == nil ? 1.4 : 2
      }
    dwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      if !Task.isCancelled { self?.dismiss() }
    }
  }

  /// 收起：内容先退（0.12 s），0.08 s 后形体缩回刘海，动画结束再移走窗口
  func dismiss() {
    dwell?.cancel()
    guard isOpen else { return }
    withAnimation(.easeIn(duration: 0.12)) { content = nil }
    dwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.2))
      guard let self, !Task.isCancelled else { return }
      withAnimation(Style.Motion.retract.animation(), completionCriteria: .logicallyComplete) {
        self.isOpen = false
      } completion: { [weak self] in
        guard let self, !self.isOpen else { return }
        self.window?.orderOut(nil)
      }
    }
  }

  private func open(with next: Content) {
    let window = self.window ?? makeWindow()
    self.window = window
    if !isOpen || !window.isVisible { place(window) }
    window.orderFrontRegardless()
    content = nil
    // 先让形体从刘海 / 小胶囊长开，内容由自己的过渡晚 60 ms 出场
    withAnimation(Style.Motion.island.animation()) {
      isOpen = true
      content = next
    }
  }

  /// 放到鼠标所在屏顶部正中（刘海屏贴着顶边，其它屏在菜单栏下方）
  private func place(_ window: NSPanel) {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
        ?? NSScreen.main
    else { return }
    geometry = Self.geometry(of: screen)
    let size = geometry.windowSize
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    let top =
      if case .notch = geometry { screen.frame.maxY } else { screen.frame.maxY - menuBar - 8 }
    window.setFrame(
      CGRect(
        x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width,
        height: size.height),
      display: false)
    (window.contentView as? NSHostingView<IslandView>)?.rootView = IslandView(island: self)
  }

  /// 刘海：左右两块 auxiliary 区都在、且顶部安全区 > 0；刘海宽 = 屏宽 − 两块区宽 + 4（盖住抗锯齿毛边）
  static func geometry(of screen: NSScreen) -> Geometry {
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
      screen.safeAreaInsets.top > 0
    {
      return .notch(
        width: screen.frame.width - left.width - right.width + 4, height: screen.safeAreaInsets.top)
    }
    return .capsule(menuBar: screen.frame.maxY - screen.visibleFrame.maxY)
  }

  private func makeWindow() -> NSPanel {
    let panel = NSPanel(
      contentRect: CGRect(origin: .zero, size: geometry.windowSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let host = NSHostingView(rootView: IslandView(island: self))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  /// 窗口不接鼠标，VoiceOver 读不到：主动播报
  private func announce(_ content: Content) {
    let text = [content.title, content.detail].compactMap { $0 }.joined(separator: "，")
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  private static func symbol(for tone: Tone) -> String {
    switch tone {
    case .success: "checkmark.circle.fill"
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.circle.fill"
    case .progress: "ellipsis.circle.fill"
    }
  }
}

/// 岛的画面：黑色形体（刘海屏带耳朵的下巴 / 其它屏的胶囊）+ 一行内容
struct IslandView: View {
  let island: Island
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 有内容时的宽度：内容先退场、形体再缩回的那一小段里冻住它，免得宽度先跳一下
  @State private var heldWidth: CGFloat = 0

  var body: some View {
    let geometry = island.geometry
    ZStack(alignment: .top) {
      shape(geometry)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder private func shape(_ geometry: Island.Geometry) -> some View {
    let open = island.isOpen
    // 减弱动态效果：刘海下巴不伸缩，只淡入淡出
    let sized = open || reduceMotion
    let held = sized && island.content == nil ? heldWidth : 0
    switch geometry {
    case .notch(let notchWidth, let notchHeight):
      row
        .frame(height: Island.chin)
        .padding(.top, notchHeight)
        // 只设最小宽度、横向贴合内容（内容自己限宽）；收起时就是刘海大小
        .frame(
          minWidth: sized ? max(notchWidth + 64, held) : notchWidth,
          minHeight: sized ? notchHeight + Island.chin : notchHeight,
          maxHeight: sized ? notchHeight + Island.chin : notchHeight, alignment: .top
        )
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: { width in
          if island.content != nil { heldWidth = width }
        }
        .background(
          IslandShape(ear: sized ? 10 : 6, bottom: sized ? 22 : 10)
            .fill(.black)
            .shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, y: 6)
        )
        .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
        .opacity(reduceMotion && !open ? 0 : 1)
    case .capsule:
      let capsule = Capsule(style: .continuous)
      row
        .frame(height: Island.chin)
        .frame(minWidth: max(120, held), maxWidth: Island.maxWidth)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: { width in
          if island.content != nil { heldWidth = width }
        }
        .background(capsule.fill(.black.opacity(0.92)))
        .overlay(capsule.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 12, y: 5)
        .scaleEffect(open || reduceMotion ? 1 : 0.6, anchor: .top)
        .opacity(open ? 1 : 0)
        .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
        .padding(.top, 2)
    }
  }

  /// 一行内容：前导 + 标题 + 详情。换内容时模糊交叉替换，首次出场晚 60 ms
  @ViewBuilder private var row: some View {
    ZStack {
      if let content = island.content {
        HStack(spacing: 10) {
          leading(content)
          Text(content.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
          if let detail = content.detail {
            Text(detail)
              .font(.system(size: 13))
              .foregroundStyle(.white.opacity(0.55))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: 280, alignment: .leading)
          }
        }
        .padding(.horizontal, 18)
        .fixedSize(horizontal: true, vertical: false)
        .id(content.title + (content.detail ?? ""))
        .transition(
          reduceMotion
            ? .opacity
            : .asymmetric(
              insertion: .modifier(
                active: Emerge(progress: 0), identity: Emerge(progress: 1)
              ).animation(.smooth(duration: 0.28).delay(0.06)),
              removal: .opacity.animation(.easeIn(duration: 0.12))))
      }
    }
  }

  @ViewBuilder private func leading(_ content: Island.Content) -> some View {
    switch content.leading {
    case .color(let color):
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: color))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
            .white.opacity(0.25), lineWidth: 1)
        )
        .frame(width: 22, height: 22)
    case .thumbnail(let image):
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 26, height: 18)
        .clipShape(.rect(cornerRadius: 4, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(
            .white.opacity(0.25), lineWidth: 0.5))
    case .tone:
      Image(systemName: content.symbol)
        .font(.system(size: 18, weight: .semibold))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, tint(content.tone))
        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
        .symbolEffect(.breathe.pulse, isActive: content.tone == .progress && !reduceMotion)
        .symbolEffect(.bounce, value: content.tone == .success ? content.title : "")
        .frame(width: 22, height: 22)
    }
  }

  private func tint(_ tone: Island.Tone) -> Color {
    switch tone {
    case .success: Color(nsColor: .systemGreen)
    case .info, .progress: Color.accentColor
    case .warning: Color(nsColor: .systemOrange)
    case .error: Color(nsColor: .systemRed)
    }
  }
}

/// 内容出场：blur 8 → 0、scale 0.9 → 1（顶部锚点）、透明度
private struct Emerge: ViewModifier {
  let progress: Double

  func body(content: Content) -> some View {
    content
      .blur(radius: 8 * (1 - progress))
      .scaleEffect(0.9 + 0.1 * progress, anchor: .top)
      .opacity(progress)
  }
}

/// 错误时整座岛左右抖：0, −7, 6, −4, 2, 0，共 0.4 s
private struct Shake: ViewModifier {
  let count: Int
  let enabled: Bool

  func body(content: Content) -> some View {
    content.keyframeAnimator(initialValue: CGFloat(0), trigger: count) { view, x in
      view.offset(x: enabled ? x : 0)
    } keyframes: { _ in
      KeyframeTrack {
        LinearKeyframe(-7, duration: 0.07)
        LinearKeyframe(6, duration: 0.08)
        LinearKeyframe(-4, duration: 0.08)
        LinearKeyframe(2, duration: 0.08)
        LinearKeyframe(0, duration: 0.09)
      }
    }
  }
}

/// 刘海岛形体：顶边两侧向外弯出的「耳朵」（凹弧接到菜单栏顶边）+ 圆角下巴。耳朵和底角半径可动画
struct IslandShape: Shape {
  var ear: CGFloat
  var bottom: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(ear, bottom) }
    set {
      ear = newValue.first
      bottom = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let ear = min(ear, rect.width / 4, rect.height / 2)
    let bottom = min(bottom, (rect.width - ear * 2) / 2, rect.height - ear)
    var path = Path()
    path.move(to: CGPoint(x: rect.minX - ear, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.minY + ear), control: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + bottom, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ear))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX + ear, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
  }
}
