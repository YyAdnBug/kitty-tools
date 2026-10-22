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

  /// 前导位置：按语气出符号（一律是语气色的圆底 + 上面的符号，见 hasPlate），或者取色的色块、截图的缩略图
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
    /// 进行中、且知道做到哪了（0…1：更新包下载、转 GIF、压缩）：标题后面多一条细进度条。nil = 不画
    var fraction: Double?
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
  /// 语气变了（nil = 收起）：菜单栏图标据此呼吸 / 弹一下（StatusItem.reflect）
  @ObservationIgnored var onToneChange: ((Tone?) -> Void)?
  /// 岛上那一个动作（「撤销」「在访达中显示」）：有它时窗口接鼠标，点完就收起。内容变了就换 / 清掉
  private(set) var actionTitle: String?
  @ObservationIgnored private var action: (() -> Void)?

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

  /// 详情里的一句摘录：第一行前 24 个字，后面还有就补「…」（\r\n、\r、U+2028 都算换行）
  static func excerpt(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = trimmed.prefix { !$0.isNewline }.prefix(24)
    return head + (head.count < trimmed.count ? "…" : "")
  }

  /// 前导位置的截图缩略图：同飞行卡片取顶部一段，缩到 26×18 的两倍像素。
  /// 不把整张原图放进岛（长截图可到 4000 万像素，岛要挂 1.4–2 s）
  static func thumbnail(of image: CGImage) -> Leading {
    let top = FlyCard.visiblePart(of: image, frame: CGRect(x: 0, y: 0, width: 26, height: 18))
    return .thumbnail(
      NSImage(
        cgImage: FlyCard.thumbnail(of: top, fitting: CGSize(width: 52, height: 36)), size: .zero))
  }

  /// 下巴 / 胶囊高度
  static let chin: CGFloat = 36
  static let maxWidth: CGFloat = 460

  func show(
    _ title: String, detail: String? = nil, tone: Tone = .success, symbol: String? = nil,
    leading: Leading = .tone, fraction: Double? = nil,
    action: (title: String, run: () -> Void)? = nil
  ) {
    let next = Content(
      title: title, detail: detail, tone: tone, symbol: symbol ?? Self.symbol(for: tone),
      leading: leading, fraction: fraction)
    actionTitle = action?.title
    self.action = action?.run
    window?.ignoresMouseEvents = action == nil
    dwell?.cancel()
    if isOpen, content != nil {
      // 原地更新：内容交叉模糊替换，宽度跟着内容走（spring 0.32）
      withAnimation(Self.resize) { content = next }
    } else {
      open(with: next)
    }
    if tone == .error { shakes += 1 }
    onToneChange?(tone)
    // 窗口不接鼠标，VoiceOver 读不到：主动播报
    Self.announce([next.title, next.detail].compactMap { $0 }.joined(separator: "，"))
    // 带动作（「撤销」「在访达中显示」）的岛多留一会儿：1.4–2 秒来不及挪鼠标去点（G23）
    let seconds: Double =
      switch tone {
      case .progress: 60
      case .error: action == nil ? 3 : 6
      default: action == nil ? (detail == nil ? 1.4 : 2) : 6
      }
    dwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      if !Task.isCancelled { self?.dismiss() }
    }
  }

  /// 岛的宽度跟着内容变时用的曲线
  private static var resize: Animation {
    Style.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.15)
  }

  /// 进行中的岛改详情（更新包下载、转 GIF、压缩的百分比；fraction 是同一个进度，细进度条跟着走）：内容不重新出场、不播报
  /// （一秒几次，旁白会被刷屏），停留重新计时——事情还在做就一直挂着。岛上已经不是这一条（标题对不上、被别的岛换掉了）就不动
  func progress(_ title: String, detail: String, fraction: Double? = nil) {
    guard isOpen, let content, content.title == title, content.tone == .progress,
      content.detail != detail || content.fraction != fraction
    else { return }
    // 细条刚出现 / 收掉时宽度变一大截，同原地更新的弹簧；平时只是数字在变，不动画
    withAnimation((content.fraction == nil) != (fraction == nil) ? Self.resize : nil) {
      self.content?.detail = detail
      self.content?.fraction = fraction
    }
    dwell?.cancel()
    dwell = Task { [weak self] in
      try? await Task.sleep(for: .seconds(60))
      if !Task.isCancelled { self?.dismiss() }
    }
  }

  /// 慢活的「进行中」岛：work 超过 delay 还没做完才出（很快做完的不闪这一下）。做完之后调用方出结果岛就原地换掉它；
  /// 没有结果岛的调用方自己收（content?.title 还是这一条就 dismiss）
  func showIfSlow<T>(
    _ title: String, symbol: String? = nil, after delay: Duration = .milliseconds(300),
    _ work: () async -> T
  ) async -> T {
    await Self.whenSlow(
      after: delay, notice: { [weak self] in self?.show(title, tone: .progress, symbol: symbol) },
      work: work)
  }

  /// work 超过 delay 还没做完才调 notice（单测不建岛的窗口，直接测这个）
  static func whenSlow<T>(
    after delay: Duration, notice: @escaping () -> Void, work: () async -> T
  ) async -> T {
    let pending = Task {
      try? await Task.sleep(for: delay)
      if !Task.isCancelled { notice() }
    }
    defer { pending.cancel() }
    return await work()
  }

  /// 点岛上那个动作：先收起再跑（跑之前岛已经不在，动作里弹面板不会和岛抢）
  func performAction() {
    let run = action
    action = nil
    actionTitle = nil
    window?.ignoresMouseEvents = true
    dismiss()
    run?()
  }

  /// 收起：内容先退（0.12 s），0.08 s 后形体缩回刘海，动画结束再移走窗口
  func dismiss() {
    dwell?.cancel()
    guard isOpen else { return }
    actionTitle = nil
    action = nil
    window?.ignoresMouseEvents = true
    onToneChange?(nil)
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
    // 本 App 失活时不收（NSPanel 默认收；收回浮动便签后 NoteFloats.returnKeyboard 会 deactivate 一次）
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = action == nil
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let host = IslandHost(rootView: IslandView(island: self))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  /// VoiceOver 主动播报（全 App 同一个入口）：焦点一直在搜索框 / 原文框，或者窗口本来就不接鼠标（岛、钉图、飞行卡片），
  /// 看不到焦点的变化要自己说出来
  static func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  /// 自带实心底的符号（xxx.circle.fill，还有警告默认的三角、强制结束的八角）：「符号一种颜色、底是语气色」的两色画法
  /// 只有它们画得对。别的（裸符号、空心圆）两色会整个画成第一种颜色、语气色不出现，宽的还会撑出前导槽——由岛垫一个
  /// 语气色圆（IslandView.leading）。调用处：有圆底变体的传圆底变体，没有的照传，岛来垫
  static func hasPlate(_ symbol: String) -> Bool {
    [".circle.fill", ".triangle.fill", ".octagon.fill"].contains { symbol.hasSuffix($0) }
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
            .islandShadow(open: open)
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
        .overlay(capsule.hairlineBorder(.white.opacity(0.12)))
        .islandShadow(open: open)
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
          if let fraction = content.fraction {
            // 知道做到哪了（下载、转 GIF、压缩）：56 × 4 的细条，底 white 0.18、填语气色，跟着进度线性走
            Capsule().fill(.white.opacity(0.18))
              .overlay(alignment: .leading) {
                Rectangle().fill(tint(content.tone))
                  .frame(width: 56 * min(max(fraction, 0), 1))
              }
              .clipShape(Capsule())
              .frame(width: 56, height: 4)
              .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
              .accessibilityHidden(true)
          }
          if let detail = content.detail {
            Text(detail)
              // 进行中的详情是会变的百分比：数字等宽，岛不跟着一宽一窄地抖
              .font(
                content.tone == .progress ? .system(size: 13).monospacedDigit() : .system(size: 13)
              )
              .foregroundStyle(.white.opacity(0.55))
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: 280, alignment: .leading)
          }
          if let title = island.actionTitle {
            Button(title) { island.performAction() }
              .buttonStyle(.plain)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(Capsule(style: .continuous).fill(.white.opacity(0.16)))
              .accessibilityLabel(title)
          }
        }
        .padding(.horizontal, 18)
        .fixedSize(horizontal: true, vertical: false)
        // 进行中的岛只按标题认：详情里的百分比一直在变，不能每变一次就整行重新出场
        .id(content.tone == .progress ? content.title : content.title + (content.detail ?? ""))
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
    // 色块和缩略图的描边同一种：发丝线（0.5 pt，增强对比度 1 pt）
    case .color(let color):
      let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
      shape.fill(Color(nsColor: color))
        .overlay(shape.hairlineBorder(.white.opacity(0.25)))
        .frame(width: 22, height: 22)
    case .thumbnail(let image):
      let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 26, height: 18)
        .clipShape(shape)
        .overlay(shape.hairlineBorder(.white.opacity(0.25)))
    case .tone:
      // 底上的符号：成功 / 警告 / 错误是白的；信息 / 进行中的底是强调色，黄、橙、绿这些亮强调色上要换深色
      let ink = content.tone == .info || content.tone == .progress ? Style.onBrand : .white
      Group {
        if Island.hasPlate(content.symbol) {
          Image(systemName: content.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(ink, tint(content.tone))
        } else {
          // 没有圆底变体的符号：垫一个语气色圆。圆是同字号的 circle.fill，和 xxx.circle.fill 的圆一样大（约 18.5 pt）；
          // 符号放进 12 × 12（和系统圆底符号里的那个差不多大），宽的（键盘、带角标的文件夹）跟着缩，不出圆
          Image(systemName: "circle.fill")
            .foregroundStyle(tint(content.tone))
            .overlay {
              Image(systemName: content.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(ink)
            }
        }
      }
      .font(.system(size: 18, weight: .semibold))
      .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
      .symbolEffect(.breathe.pulse, isActive: content.tone == .progress && !reduceMotion)
      .symbolEffect(.bounce, value: content.tone == .success ? content.title : "")
      .frame(width: 22, height: 22)
    }
  }

  private func tint(_ tone: Island.Tone) -> Color {
    switch tone {
    case .success: Color(nsColor: .systemGreen)
    case .info, .progress: Style.brand
    case .warning: Color(nsColor: .systemOrange)
    case .error: Color(nsColor: .systemRed)
    }
  }
}

extension View {
  /// 展开态的阴影（mac-whisker §3「层级」：black 0.45 / 模糊 14 / 向下 6）：刘海下巴和无刘海的胶囊同一组
  fileprivate func islandShadow(open: Bool) -> some View {
    shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, y: 6)
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

/// 刘海岛形体：顶边两侧向外弯出的「耳朵」（凹弧接到菜单栏顶边）+ 圆角下巴。耳朵和底角半径可动画
/// nonisolated：path(in:) 可能在 SwiftUI 的异步渲染线程上调，纯几何计算，不绑定主线程
nonisolated struct IslandShape: Shape {
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

/// 岛的宿主：带动作时第一下点击就给按钮（本 App 不在前台时也一样，G23）；不带动作时窗口整个不接鼠标，这一条不起作用
private final class IslandHost: NSHostingView<IslandView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
