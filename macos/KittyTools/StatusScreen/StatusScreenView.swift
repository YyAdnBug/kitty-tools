// 状态屏的面板和画面（PLAN §10「状态屏」Z5 Z7 Z8）：每块屏一张全屏面板，底色按样式（熄屏、告示纯黑，透出压暗），
// 中间一列图标、标题、说明、「几点开始 · 已经多久」（透出样式垫一块 HUD 底板：后面是别人的窗口，字会叠在一起），
// 底部一枚平时不显示的退出提示（进度环 +「按住 Esc 退出」）。告示那一列每分钟挪几个点，防残影。
// 永远深色，颜色取自 HUD 皮肤（Style.HUD），进度环是截图家族的强调色（Style.Shot.accent）。
// StatusScreenPanel 是「禁止另写 NSPanel 子类」的第四个例外（前三个：截图遮罩 SelectionOverlay、钉图 PinPanel、长截图面板
// ScrollCapturePanel，mac-overlay-panel §1）：无边框窗口默认当不了 key，而安全输入开着时按键只能靠 key 面板接。
// 层级是 CGShieldingWindowLevel（盖住菜单栏、程序坞、通知横幅），不抢前台：**永远不调 NSApp.activate**。
// 从选状态的面板进来时（Z14a），卡片所在屏的那张不淡入，画面从选中的卡片长到整屏（present(growingFrom:)）。
// 文件末尾的 StatusPreview 是缩小的同一个画面：设置里改一个状态时的预览、选状态面板里的卡片共用。

import AppKit
import SwiftUI

final class StatusScreenPanel: NSPanel {
  /// 落到面板上的事件（平时被拦截吞了、到不了这里；安全输入开着时的按键、拦截被系统停用那一阵的鼠标键才走这条路）
  var onKey: (InputBlock.Event) -> Void = { _ in }
  var onMouseMoved: () -> Void = {}
  var onResignKey: () -> Void = {}

  init(frame: CGRect, session: StatusScreen) {
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    hasShadow = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    // 本 App 有模态窗口时照样收事件
    worksWhenModal = true
    // 不透明的两种样式窗口自己也铺底色（画面出第一帧之前不漏桌面）；透出的底由画面画，窗口透明
    let style = session.preset?.style ?? .blackout
    isOpaque = style != .dim
    backgroundColor = style == .dim ? .clear : Self.backdrop(style)
    let host = NSHostingView(rootView: StatusScreenView(screen: session))
    host.sizingOptions = []
    // 不是 key 的那几块屏也要报鼠标移动
    host.addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    contentView = host
    setFrame(frame, display: false)
  }

  /// 底色：熄屏、告示纯黑；透出是整屏压暗（Style.HUD.scrim，增强对比度时压得更深）
  static func backdrop(_ style: StatusPreset.Look) -> NSColor {
    style == .dim ? Style.HUD.scrim : .black
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// 无边框窗口也别被挪到菜单栏下面
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  override func resignKey() {
    super.resignKey()
    onResignKey()
  }

  /// 按键不往下派发（不进响应链、不响提示音），直接交给会话；修饰键只吞。鼠标键、滚轮平时到不了这里，
  /// 到了说明拦截这一阵没在工作：照样交给会话，按住退出提示这条路不断
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .keyDown: onKey(Self.keyDown(event))
    case .keyUp: onKey(.keyUp(code: Int(event.keyCode)))
    case .flagsChanged: break
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: onMouseMoved()
    case .leftMouseDown: onKey(.leftDown(at: NSEvent.mouseLocation))
    case .leftMouseUp: onKey(.leftUp)
    case .rightMouseDown, .otherMouseDown: onKey(.touch)
    case .scrollWheel: onKey(.scroll)
    default: super.sendEvent(event)
    }
  }

  /// 带 ⌘ 的组合先走这里：不拦的话会落到本 App 的主菜单上（⌘Q 就退出了）。AppKit 不给带 ⌘ 的按键派发松开，
  /// 当场补一个，不然这个键要等 ExitHold.staleAfter 才算松开
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown {
      onKey(Self.keyDown(event))
      if event.modifierFlags.contains(.command) { onKey(.keyUp(code: Int(event.keyCode))) }
    }
    return true
  }

  private static func keyDown(_ event: NSEvent) -> InputBlock.Event {
    .keyDown(
      code: Int(event.keyCode), isRepeat: event.isARepeat,
      hasModifiers: !event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]))
  }

  /// 露出来（不抢前台；谁当 key 由会话定）。card：从选状态的面板进来时那张卡片在屏幕上的位置（Z14a），
  /// 画面从它长到整屏，不淡入
  func present(fading: Bool, growingFrom card: CGRect? = nil) {
    alphaValue = fading && card == nil ? 0 : 1
    // 要从卡片长出来的：上屏之前就让窗口透明、底色交给画面自己画（StatusScreenView 最底下铺了底色）——熄屏、告示
    // 平时是不透明黑底，不先透明的话卡片还没长大整屏就黑了；长完再恢复
    let backdrop = (isOpaque, backgroundColor)
    if card != nil {
      isOpaque = false
      backgroundColor = .clear
    }
    orderFrontRegardless()
    // 第一响应者是窗口自己，不是画面
    makeFirstResponder(nil)
    if let card {
      return Self.grow(contentView, from: card) { [weak self] in
        self?.isOpaque = backdrop.0
        self?.backgroundColor = backdrop.1
      }
    }
    guard fading else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
  }

  /// 画面（host：铺满窗口的内容视图）从 card（屏幕坐标）长到整屏：island 曲线，约 0.42 秒。窗口从头到尾都是整屏大小，
  /// 动的只是内容图层的变换（缩放 + 平移）和圆角——不做窗口帧动画、不每帧重新布局；变换和圆角的模型值不动（一直是
  /// 原位、直角），动画没加上、被移除时画面就在整屏。done：放完（或者根本没放成）时调，面板拿它把窗口的底色恢复回去。
  /// 只是画面的事：拦截、谁当 key、退出判断都不等它。不碰面板自己的东西，单测在屏外的普通窗口里跑它
  static func grow(_ host: NSView?, from card: CGRect, done: @escaping () -> Void) {
    // 动的是它自己的图层：只在要长的这一次才要（别的入口进来的面板一点不动）
    host?.wantsLayer = true
    guard let host, let window = host.window, let layer = host.layer, let parent = host.superview,
      let zoom = Style.Motion.island.caAnimation(keyPath: "transform", reduced: false)
        as? CABasicAnimation,
      // 圆角不回弹：弹过头是负的圆角
      let round = Style.Motion.island.caAnimation(
        keyPath: "cornerRadius", reduced: false, bounce: 0) as? CABasicAnimation
    else { return done() }
    // 视图的图层在上一级图层里的 frame 就是视图在上一级视图里的 frame：卡片也换到那个坐标系
    let start = zoomStart(
      from: parent.convert(window.convertFromScreen(card), from: nil), to: host.frame,
      about: layer.position)
    guard start.a > 0, start.d > 0 else { return done() }
    zoom.fromValue = NSValue(caTransform3D: CATransform3DMakeAffineTransform(start))
    zoom.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    // 卡片的圆角跟着长大、到整屏时收成直角（图层缩小了，圆角按缩放倒回去才是卡片上的那么大）；要裁才看得见圆角
    round.fromValue = Style.Radius.card / start.a
    round.toValue = 0
    let clips = host.clipsToBounds
    host.clipsToBounds = true
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak host] in
      MainActor.assumeIsolated {
        host?.clipsToBounds = clips
        done()
      }
    }
    layer.add(zoom, forKey: "grow")
    layer.add(round, forKey: "round")
    CATransaction.commit()
  }

  /// 放大的起点（纯函数）：让整屏的内容图层（在上一级图层里占 full）看起来正好落在 card 上的变换。图层的变换是绕着它的
  /// position（anchor，上一级图层的坐标）做的：上一级坐标里的点 x 画在 anchor + (x − anchor) 经过变换之后的地方。
  /// 横竖各缩各的（卡片 200 × 125 和屏幕的比例差一点），起点和卡片严丝合缝，长到整屏时变换回到原位
  static func zoomStart(from card: CGRect, to full: CGRect, about anchor: CGPoint)
    -> CGAffineTransform
  {
    guard full.width > 0, full.height > 0 else { return .identity }
    let (sx, sy) = (card.width / full.width, card.height / full.height)
    return CGAffineTransform(
      a: sx, b: 0, c: 0, d: sy, tx: card.minX - anchor.x - sx * (full.minX - anchor.x),
      ty: card.minY - anchor.y - sy * (full.minY - anchor.y))
  }

  /// 收掉：窗口当场移走，键盘马上回到前台 App；画面由系统淡出（临时 .utilityWindow 再 orderOut，同截图遮罩的取消，
  /// mac-overlay-panel §8——自己做淡出的话淡出期间还当着 key，接着打的字会被吞）。减弱动态效果、App 退出时直接消失
  func dismiss(fading: Bool) {
    animationBehavior = fading ? .utilityWindow : .none
    orderOut(nil)
    animationBehavior = .none
  }
}

struct StatusScreenView: View {
  let screen: StatusScreen
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  /// 进度环走到哪了（0–1）
  @State private var progress: Double

  init(screen: StatusScreen) {
    self.screen = screen
    _progress = State(initialValue: screen.heldProgress)
  }

  /// 标题字号跟屏幕走：屏高 × 0.075，夹在 44–96（三米外看得清）；图标、说明、小字和间距都按它的比例
  static func titleSize(screenHeight: CGFloat) -> CGFloat {
    min(max(screenHeight * 0.075, 44), 96)
  }

  var body: some View {
    let style = screen.preset?.style ?? .blackout
    GeometryReader { proxy in
      ZStack {
        Color(nsColor: StatusScreenPanel.backdrop(style))
        if let preset = screen.preset, style != .blackout {
          sign(preset, in: proxy.size)
        }
        hint
          .position(
            x: proxy.size.width / 2,
            y: proxy.size.height - StatusScreen.hintBottom - StatusScreen.hintSize.height / 2)
      }
    }
    .ignoresSafeArea()
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      ["状态屏", screen.preset?.title, screen.preset?.detail, "按住 Esc 两秒退出"]
        .compactMap { $0 }.joined(separator: "，")
    )
    .onChange(of: screen.isHolding) { _, holding in
      // 按住：线性走满，和退出判断同一个时长；取消：snap 缩回（减弱动态效果时直接回去）
      if holding {
        withAnimation(.linear(duration: ExitHold.seconds)) { progress = 1 }
      } else {
        withAnimation(Style.Motion.snap.animation(reduced: reduceMotion)) { progress = 0 }
      }
    }
  }

  /// 告示：中间一列。透出样式垫一块 HUD 底板（面板圆角；降低透明度、增强对比度由 HUD 皮肤自己管），告示样式底是纯黑、不用垫
  @ViewBuilder private func sign(_ preset: StatusPreset, in size: CGSize) -> some View {
    let title = Self.titleSize(screenHeight: size.height)
    Group {
      if preset.style == .dim {
        column(preset, title: title)
          .padding(.horizontal, title * 0.7)
          .padding(.vertical, title * 0.55)
          .hudSkin(RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous))
      } else {
        column(preset, title: title)
      }
    }
    .padding(.horizontal, size.width * 0.1)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // 防残影：每分钟挪几个点（StatusScreen.drift）；减弱动态效果时直接换位置
    .offset(screen.drift)
    .animation(reduceMotion ? nil : Style.Motion.settle.animation(), value: screen.drift)
  }

  private func column(_ preset: StatusPreset, title: CGFloat) -> some View {
    // 说明和小字是给路过的人隔着距离看的：用第二档文字色，增强对比度时提到第一档
    let minor = Color(nsColor: contrast == .increased ? Style.HUD.text : Style.HUD.secondaryText)
    return VStack(spacing: 0) {
      if !preset.symbol.isEmpty {
        Image(systemName: preset.symbol)
          .font(.system(size: title * 0.8, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color(nsColor: Style.HUD.text))
          .padding(.bottom, title * 0.3)
      }
      Text(preset.title)
        .font(.system(size: title, weight: .bold, design: .rounded))
        .foregroundStyle(Color(nsColor: Style.HUD.text))
        .lineLimit(2)
        .minimumScaleFactor(0.5)
        .modifier(Shake(count: screen.shakes, enabled: !reduceMotion))
      if let detail = preset.detail {
        Text(detail)
          .font(.system(size: title * 0.36))
          .foregroundStyle(minor)
          .lineLimit(3)
          .padding(.top, title * 0.25)
      }
      Text(screen.footer)
        .font(.system(size: max(13, title * 0.2)).monospacedDigit())
        .foregroundStyle(minor)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, title * 0.5)
    }
    .multilineTextAlignment(.center)
  }

  /// 退出提示：HUD 胶囊（高 40，同截图家族的 HUD 条），进度环 +「按住 Esc 退出」。按住 esc 或用鼠标按住它，环 2 秒走满。
  /// 大小固定（StatusScreen.hintSize：鼠标按住的命中按它算）。出现时浮上 8 pt（同截图顶部的提示）
  private var hint: some View {
    let ring = StrokeStyle(lineWidth: 2.5, lineCap: .round)
    return HStack(spacing: 6) {
      ZStack {
        Circle().stroke(Color(nsColor: Style.HUD.separator), style: ring)
        Circle().trim(from: 0, to: progress)
          .stroke(Color(nsColor: Style.Shot.accent), style: ring)
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 20, height: 20)
      .padding(.trailing, 2)
      Text("按住")
      KeyCap("Esc")
      Text("退出")
    }
    .font(.system(size: 13, weight: .medium))
    .lineLimit(1)
    .frame(width: StatusScreen.hintSize.width, height: StatusScreen.hintSize.height)
    .hudSkin(Capsule())
    .opacity(screen.showsHint ? 1 : 0)
    .offset(y: screen.showsHint || reduceMotion ? 0 : 8)
    .animation(
      screen.showsHint ? .easeOut(duration: Style.fadeIn) : .easeIn(duration: Style.fadeOut),
      value: screen.showsHint)
  }
}

/// 缩小的状态屏：真的画面（StatusScreenView）按一块 1200 × 750 的屏排好，再缩到给它的宽度（宽高比 1.6）。透出样式底下垫
/// 一张示意的浅色桌面（画的，不截真屏幕）。进入时刻、时长是摆的，不带退出提示。只是个样子：不接点击、不进旁白。
/// 设置 › 状态屏改一个状态时的预览（StatusPresetDetail）、选状态面板里的卡片（StatusPicker）共用
struct StatusPreview: View {
  let preset: StatusPreset

  private static let screen = CGSize(width: 1200, height: 750)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let startedAt =
      Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: .now) ?? .now
    GeometryReader { proxy in
      ZStack {
        if preset.style == .dim { Self.desktop }
        StatusScreenView(
          screen: StatusScreen(showing: preset, startedAt: startedAt, elapsed: 23 * 60))
      }
      .frame(width: Self.screen.width, height: Self.screen.height)
      .scaleEffect(proxy.size.width / Self.screen.width, anchor: .topLeading)
    }
    .aspectRatio(Self.screen.width / Self.screen.height, contentMode: .fit)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  /// 示意的桌面：浅色壁纸上两扇有几行「字」的窗。颜色是示意用的定值，不跟外观走
  private static var desktop: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color(red: 0.62, green: 0.74, blue: 0.92), Color(red: 0.84, green: 0.80, blue: 0.94),
        ], startPoint: .top, endPoint: .bottom)
      window(lines: 9).frame(width: 640, height: 440).offset(x: -200, y: -70)
      window(lines: 6).frame(width: 520, height: 340).offset(x: 260, y: 140)
    }
  }

  private static func window(lines: Int) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(0..<lines, id: \.self) { line in
        Capsule()
          .fill(.black.opacity(line == 0 ? 0.6 : 0.3))
          .frame(width: line == 0 ? 180 : line % 3 == 0 ? 260 : 400, height: 12)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
