// 状态屏的面板和画面（PLAN §10「状态屏」Z5 Z7 Z8）：每块屏一张全屏面板，底色按样式（熄屏、告示纯黑，透出压暗），
// 中间一列图标、标题、说明、「几点开始 · 已经多久」（透出样式垫一块 HUD 底板：后面是别人的窗口，字会叠在一起），
// 底部一枚平时不显示的退出提示（进度环 +「按住 Esc 退出」）。告示那一列每分钟挪几个点，防残影。
// 永远深色，颜色取自 HUD 皮肤（Style.HUD），进度环是截图家族的强调色（Style.Shot.accent）。
// StatusScreenPanel 是「禁止另写 NSPanel 子类」的第四个例外（前三个：截图遮罩 SelectionOverlay、钉图 PinPanel、长截图面板
// ScrollCapturePanel，mac-overlay-panel §1）：无边框窗口默认当不了 key，而安全输入开着时按键只能靠 key 面板接。
// 层级是 CGShieldingWindowLevel（盖住菜单栏、程序坞、通知横幅），不抢前台：**永远不调 NSApp.activate**。

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

  /// 露出来（不抢前台；谁当 key 由会话定）
  func present(fading: Bool) {
    alphaValue = fading ? 0 : 1
    orderFrontRegardless()
    // 第一响应者是窗口自己，不是画面
    makeFirstResponder(nil)
    guard fading else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
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
