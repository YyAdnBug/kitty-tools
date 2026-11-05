// 提醒的全屏（PLAN §10「提醒」C4–C8）：每块屏一张面板，借状态屏的画面——透出样式（整屏压暗、看得见后面的窗口）+ 中间一块
// HUD 底板：表情、标题（几条合在一起）、说明、现在几点、「N 秒后自己收起」，下面一排按钮：稍后 5 分钟 / 15 分钟 / 1 小时、知道了。
// 和状态屏的根本区别：不拦键盘鼠标、不要授权，按钮直接点。鼠标所在那块屏的面板当 key，↩ / Esc = 知道了（C6），稍后只能点；
// 出现后 1 秒内的按键、点击都不算，按钮这 1 秒里淡入（C7，正在打字时弹出来，下一下回车不会把它关掉）。
// 设了时长的到点自己收 = 知道了（C5）。进入状态屏没进去时（C12）底板上多一行橙字说为什么，缺授权的带「去授权」。
// ReminderScreenPanel 是「禁止另写 NSPanel 子类」的第九个例外（mac-overlay-panel §1）：无边框窗口默认当不了 key，而 ↩ / Esc
// 要收按键；它不吞事件（不同于状态屏的面板），鼠标点按钮照常走 SwiftUI，带 ⌘ 的组合吞掉（不然 ⌘Q 落到主菜单上退出了 App）。
// 层级同状态屏（CGShieldingWindowLevel：盖住菜单栏、程序坞、通知横幅），不调 NSApp.activate。
// 表情的帧在主线程外解好再换上（同状态屏，解完之前是静止画面；减弱动态效果时只用静止画面），收起时放掉。

import AppKit
import SwiftUI

@MainActor final class ReminderScreen {
  /// 底板上写什么
  struct Content: Equatable {
    var title: String
    var detail: String?
    /// 表情 id；空 = 不要
    var symbol: String
    /// 多久自己收（秒；0 = 点了才收）
    var seconds: Int
    /// 「稍后」的几个选项（分钟）
    var snoozes: [Int]
    /// 进入状态屏没进去的原因（C12）；grants：缺授权，带「去授权」
    var note: (text: String, grants: Bool)?

    static func == (lhs: Self, rhs: Self) -> Bool {
      (lhs.title, lhs.detail, lhs.symbol, lhs.seconds, lhs.snoozes)
        == (rhs.title, rhs.detail, rhs.symbol, rhs.seconds, rhs.snoozes)
        && lhs.note?.text == rhs.note?.text && lhs.note?.grants == rhs.note?.grants
    }
  }

  var onDone: () -> Void = {}
  var onSnooze: (Int) -> Void = { _ in }
  var onGrant: () -> Void = {}
  private let model = ReminderScreenModel()
  private var panels: [ReminderScreenPanel] = []
  private var countdown: Timer?
  private var guardTask: Task<Void, Never>?
  private var framesTask: Task<Void, Never>?

  /// 出现后多久之内的按键、点击不算（C7）
  static let settleTime: Duration = .seconds(1)

  var isShowing: Bool { !panels.isEmpty }

  /// 出来；已经在了就原地换内容（又有一条到点、合成一条），时长从这一刻重新数
  func show(_ content: Content) {
    let changedSymbol = model.content?.symbol != content.symbol
    model.content = content
    model.remaining = content.seconds
    startCountdown(content.seconds)
    if changedSymbol { loadFrames(content.symbol) }
    // 换了内容（又有一条合进来）也重新等那 1 秒：正要点给旧内容的那一下，不能把没看到的新一条处理掉
    settle()
    guard panels.isEmpty else { return }
    let mouse = NSEvent.mouseLocation
    for screen in NSScreen.screens {
      let panel = ReminderScreenPanel(frame: screen.frame, model: model)
      panel.onKey = { [weak self] in self?.key() }
      panel.done = { [weak self] in self?.done() }
      panel.snooze = { [weak self] in self?.snooze($0) }
      panel.grant = { [weak self] in self?.onGrant() }
      panel.present(fading: !Style.reduceMotion)
      panels.append(panel)
    }
    // 鼠标所在那块屏的当 key（贴着屏幕顶边时 contains 不算，用 NSMouseInRect；哪块都不在就第一块，同状态屏）
    let key = zip(NSScreen.screens, panels).first { NSMouseInRect(mouse, $0.0.frame, false) }?.1
    (key ?? panels.first)?.makeKey()
    Island.announce(
      [content.title, content.detail].compactMap { $0 }.joined(separator: "，") + "。回车表示知道了")
  }

  /// 按钮先藏起来、1 秒后淡入（C7）
  private func settle() {
    guardTask?.cancel()
    model.isSettled = false
    guardTask = Task { [weak self] in
      try? await Task.sleep(for: Self.settleTime)
      guard !Task.isCancelled, let self else { return }
      withAnimation(.easeOut(duration: Style.fadeIn)) { self.model.isSettled = true }
    }
  }

  func dismiss() {
    guard isShowing else { return }
    countdown?.invalidate()
    countdown = nil
    guardTask?.cancel()
    framesTask?.cancel()
    for panel in panels { panel.dismiss(fading: !Style.reduceMotion) }
    panels = []
    model.content = nil
    model.frames = nil
  }

  private func key() {
    if model.isSettled { done() }
  }

  private func done() {
    guard model.isSettled else { return }
    onDone()
  }

  private func snooze(_ minutes: Int) {
    guard model.isSettled else { return }
    onSnooze(minutes)
  }

  /// 设了时长的每秒数一下，到 0 自己收 = 知道了（不看 isSettled：时长至少 20 秒）
  private func startCountdown(_ seconds: Int) {
    countdown?.invalidate()
    countdown = nil
    guard seconds > 0 else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.model.remaining -= 1
        if self.model.remaining <= 0 { self.onDone() }
      }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    countdown = timer
  }

  /// 表情的帧在主线程外解（同状态屏）；减弱动态效果时只用静止画面
  private func loadFrames(_ symbol: String) {
    framesTask?.cancel()
    model.frames = nil
    guard !symbol.isEmpty, !Style.reduceMotion else { return }
    framesTask = Task { [weak self] in
      let frames = await StatusEmoji.load(symbol)
      guard !Task.isCancelled, let self, self.model.content?.symbol == symbol else { return }
      self.model.frames = frames
    }
  }
}

/// 画面读的状态（几块屏共用一份）
@Observable final class ReminderScreenModel {
  var content: ReminderScreen.Content?
  /// 还剩几秒自己收
  var remaining = 0
  /// 过了出现后的那 1 秒：按钮能点、按键算数
  var isSettled = true
  var frames: StatusEmoji.Frames?

  init(content: ReminderScreen.Content? = nil, remaining: Int = 0, isSettled: Bool = true) {
    self.content = content
    self.remaining = remaining
    self.isSettled = isSettled
  }
}

final class ReminderScreenPanel: NSPanel {
  var onKey: () -> Void = {}
  var done: () -> Void = {}
  var snooze: (Int) -> Void = { _ in }
  var grant: () -> Void = {}

  init(frame: CGRect, model: ReminderScreenModel) {
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
    worksWhenModal = true
    isOpaque = false
    backgroundColor = .clear
    // 永远深色（HUD 皮肤）：窗口外观也定成深色，里面的系统控件、动态色才和画面一致
    appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(
      rootView: ReminderScreenView(
        model: model, done: { [weak self] in self?.done() },
        snooze: { [weak self] in self?.snooze($0) }, grant: { [weak self] in self?.grant() }))
    host.sizingOptions = []
    // 宿主包在普通容器里（mac-overlay-panel §1 setHostedContent）：换屏时改面板大小不会在「更新约束」里绕下去
    setHostedContent(host)
    setFrame(frame, display: false)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  /// ↩、小键盘 Enter、Esc = 知道了；别的键吞掉（不响提示音、不进别处）
  override func keyDown(with event: NSEvent) {
    if [36, 76, 53].contains(event.keyCode) { onKey() }
  }

  override func cancelOperation(_ sender: Any?) { onKey() }

  /// 按键先过这里（AppKit 先问 key 窗口有没有对应的快捷键）：↩ / Esc 在这里也算知道了（同状态屏的面板），
  /// 带 ⌘ 的组合一律吞掉，不往主菜单派发（⌘Q 会退出 App、⌘W 没有窗口可关）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, [36, 76, 53].contains(event.keyCode) { onKey() }
    return true
  }

  func present(fading: Bool) {
    alphaValue = fading ? 0 : 1
    orderFrontRegardless()
    guard fading else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      animator().alphaValue = 1
    }
  }

  /// 收掉：窗口当场移走，键盘马上回到前台 App；画面由系统淡出（同状态屏的面板）
  func dismiss(fading: Bool) {
    animationBehavior = fading ? .utilityWindow : .none
    orderOut(nil)
    animationBehavior = .none
  }
}

/// 全屏的画面：永远深色（HUD 皮肤），整屏压暗 + 中间一块底板；字号跟状态屏的告示一样按屏高算
struct ReminderScreenView: View {
  let model: ReminderScreenModel
  var done: () -> Void = {}
  var snooze: (Int) -> Void = { _ in }
  var grant: () -> Void = {}
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color(nsColor: StatusScreenPanel.backdrop(.dim))
        if let content = model.content {
          board(content, title: StatusScreenView.titleSize(screenHeight: proxy.size.height) * 0.8)
            .padding(.horizontal, proxy.size.width * 0.1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .ignoresSafeArea()
    .environment(\.colorScheme, .dark)
  }

  private func board(_ content: ReminderScreen.Content, title: CGFloat) -> some View {
    let minorColor = contrast == .increased ? Style.HUD.text : Style.HUD.secondaryText
    return VStack(spacing: 0) {
      if !content.symbol.isEmpty {
        let side = StatusScreenView.emojiSide(title: title)
        StatusEmojiView(id: content.symbol, frames: model.frames)
          .frame(width: side, height: side)
          .padding(.bottom, title * 0.3)
          .accessibilityHidden(true)
      }
      Text(content.title)
        .font(.system(size: title, weight: .bold, design: .rounded))
        .foregroundStyle(Color(nsColor: Style.HUD.text))
        .lineLimit(2)
        .minimumScaleFactor(0.5)
      if let detail = content.detail {
        Text(detail)
          .font(.system(size: title * 0.36))
          .foregroundStyle(Color(nsColor: minorColor))
          .lineLimit(3)
          .padding(.top, title * 0.25)
      }
      footer(content, size: max(13, title * 0.22), color: minorColor)
        .padding(.top, title * 0.4)
      if let note = content.note {
        HStack(spacing: 8) {
          Text(note.text).foregroundStyle(Color(nsColor: .systemOrange))
          if note.grants {
            Button("去授权", action: grant)
              .buttonStyle(.plain)
              .foregroundStyle(Style.brandInk)
              .pointerStyle(.link)
          }
        }
        .font(.system(size: max(13, title * 0.2)))
        .padding(.top, title * 0.25)
      }
      buttons(content)
        .padding(.top, title * 0.55)
        .opacity(model.isSettled ? 1 : 0)
        .allowsHitTesting(model.isSettled)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, title * 0.7)
    .padding(.vertical, title * 0.55)
    .hudSkin(RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("提醒")
  }

  /// 现在几点（每分钟换一次）·「18 秒后自己收起」（每秒在变：图层画的 Ticker，不用 numericText，Whisker §8）
  private func footer(_ content: ReminderScreen.Content, size: CGFloat, color: NSColor)
    -> some View
  {
    HStack(spacing: 6) {
      TimelineView(.everyMinute) { context in
        Text(context.date.formatted(date: .omitted, time: .shortened))
      }
      if content.seconds > 0 {
        Text("·")
        Ticker(
          text: "\(max(model.remaining, 0)) 秒后自己收起",
          font: .systemFont(ofSize: size, weight: .medium), color: color,
          direction: reduceMotion ? 0 : -1)
      }
    }
    .font(.system(size: size, weight: .medium))
    .foregroundStyle(Color(nsColor: color))
    .monospacedDigit()
  }

  private func buttons(_ content: ReminderScreen.Content) -> some View {
    HStack(spacing: 10) {
      Text("稍后").foregroundStyle(Color(nsColor: Style.HUD.secondaryText))
      ForEach(content.snoozes, id: \.self) { minutes in
        Button(minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes) 分钟") { snooze(minutes) }
          .buttonStyle(HUDCapsuleButtonStyle())
          .accessibilityLabel("稍后 \(minutes) 分钟")
      }
      Spacer().frame(width: 12)
      Button(action: done) {
        Text("知道了")
          .padding(.horizontal, 10)
      }
      .buttonStyle(BrandButtonStyle())
      .accessibilityHint("回车或 Esc 也是知道了")
    }
    .controlSize(.large)
    .font(.system(size: 14, weight: .medium))
  }
}

/// 底板上的次要按钮（稍后几分钟）：同刘海岛上的按钮——white 0.16 的胶囊、白字，按下亮一点、缩到 0.96。
/// 不用系统的带边框按钮：它跟着窗口外观画底，屏外出图（浅色外观）是一块白、字也是白的
private struct HUDCapsuleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color(nsColor: Style.HUD.text))
      .padding(.horizontal, 14)
      .frame(height: 30)
      .background(
        Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.16))
      )
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .contentShape(Capsule())
  }
}
