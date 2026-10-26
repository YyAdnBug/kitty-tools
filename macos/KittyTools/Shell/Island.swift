// 刘海岛（Whisker 招牌时刻 S2，mac-whisker §5）：全局轻提示从刘海里长出来；没有刘海的屏幕上是菜单栏下方的黑色胶囊。
// 一个尺寸固定、不抢键盘的透明窗口（普通 NSPanel 实例，level 状态栏）放在鼠标所在屏顶部正中，
// 只让 SwiftUI 里的岛形状变形，不动画窗口 frame。内容晚 60 ms 出场；原地更新（翻译中 → 已替换）只换宽度；
// 错误时整座岛左右抖一下；消失时先退内容，再缩回刘海。停留：只有标题 1.4 s、带详情 2 s、错误 3 s、带按钮 6 s、进行中一直挂着。
// 能交互（2026-10-26 拍板，全部按推荐）：鼠标挪到岛上就停住计时、往下长成卡片（完整详情、全部按钮、×），离开 1.5 s 后收；
// 点岛本身执行「打开」类的按钮；双指往上滑收起；鼠标在岛上时来的新提示先排着。窗口平时不接鼠标，只在指针落在
// 画出来的形状上时才接（全局 + 本 App 的鼠标移动监听按位置开关），透明处和阴影那一圈照旧点穿。

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

  /// 岛上的一个按钮。第一个是最主要的：平时露在行尾，展开后在 × 左边（拍板 B2）
  struct Action {
    let title: String
    /// 打开类（在访达中显示、打开系统设置里那一项、跳到设置的某一页）：点岛本身也执行它（拍板 B3）。
    /// 撤销、取消、重试、继续这类是 false，只能点按钮
    var opens = false
    let run: () -> Void

    init(_ title: String, opens: Bool = false, run: @escaping () -> Void) {
      self.title = title
      self.opens = opens
      self.run = run
    }
  }

  /// 正在显示的内容；nil = 内容已退场（形体可能还在缩回）
  private(set) var content: Content?
  /// 形体展开着
  private(set) var isOpen = false
  /// 每次出错 +1，触发抖动
  private(set) var shakes = 0
  /// 这一条的按钮；内容换了就跟着换
  private(set) var actions: [Action] = []
  /// 鼠标停在岛上（指针动过、落在形状里才算，拍板 B6）
  private(set) var isHovered = false
  /// 长成了卡片：悬停时展开；离开后照旧开着直到收起（进行中的离开就合上，它还要挂着）
  private(set) var isExpanded = false
  @ObservationIgnored private(set) var geometry = Geometry.capsule(menuBar: 24)
  @ObservationIgnored private var window: NSPanel?
  @ObservationIgnored private var host: IslandHost?
  @ObservationIgnored private var dwell: Task<Void, Never>?
  /// 这一条到点收起的时刻；悬停时停住，离开后接着走剩下的（至少 leaveDelay）
  @ObservationIgnored private var deadline = ContinuousClock.now
  @ObservationIgnored private var remaining = Duration.zero
  /// 内容换过 / 刚展开的时刻：之后 clickGuard 以内的点击不算（拍板 B6，按钮会挪位置）
  @ObservationIgnored private var changedAt: ContinuousClock.Instant?
  /// 鼠标在岛上时来的新提示：移开再换上，只留最新一条（拍板 B5）
  @ObservationIgnored private var pending: (content: Content, actions: [Action])?
  @ObservationIgnored private var monitors: [Any] = []
  /// 悬停期间每 0.2 s 再核一次指针：从岛直接挪进本 App 不收鼠标移动的窗口时没有移动事件，靠它发现离开
  @ObservationIgnored private var hoverCheck: Task<Void, Never>?
  /// 形状在窗口里的位置（IslandView 量了报上来，左上角原点）：判断指针在不在岛上
  @ObservationIgnored var shapeFrame = CGRect.zero
  /// 语气变了（nil = 收起）：菜单栏图标据此呼吸 / 弹一下（StatusItem.reflect）
  @ObservationIgnored var onToneChange: ((Tone?) -> Void)?

  /// 刘海屏：从刘海长出下巴；其它屏：菜单栏下方的胶囊
  enum Geometry: Equatable {
    case notch(width: CGFloat, height: CGFloat)
    case capsule(menuBar: CGFloat)

    /// 窗口尺寸：最宽 460 的岛（展开成卡片最高 cardHeight）+ 两侧耳朵与阴影余量
    var windowSize: CGSize {
      switch self {
      case .notch(_, let height): CGSize(width: 520, height: height + Island.cardHeight + 26)
      case .capsule: CGSize(width: 520, height: Island.cardHeight + 34)
      }
    }
  }

  /// 摆出来的岛（截图自检、单测）：从头到尾不建窗口——收起后再 show 也不会弹到屏幕上
  @ObservationIgnored private let isStaged: Bool

  init() { isStaged = false }

  /// 截图自检、单测直接摆出某一刻的样子；正常使用就是 `Island()`
  init(
    showing content: Content?, geometry: Geometry = .capsule(menuBar: 24),
    actions: [Action] = [], expanded: Bool = false
  ) {
    isStaged = true
    self.content = content
    isOpen = content != nil
    self.geometry = geometry
    self.actions = actions
    isExpanded = expanded
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
  /// 展开的卡片最高多少（第一行 + 4 行详情 + 底边）：窗口按它一次定死
  static let cardHeight: CGFloat = 120
  /// 离开岛后至少再留多久
  static let leaveDelay = Duration.milliseconds(1500)
  static let clickGuard = Duration.milliseconds(300)

  func show(
    _ title: String, detail: String? = nil, tone: Tone = .success, symbol: String? = nil,
    leading: Leading = .tone, fraction: Double? = nil, actions: [Action] = []
  ) {
    let next = Content(
      title: title, detail: detail, tone: tone, symbol: symbol ?? Self.symbol(for: tone),
      leading: leading, fraction: fraction)
    // 鼠标正停在岛上：先排着，免得正要点的按钮被换掉（B5）。进行中的那条例外——来的是它的结果，原地换
    if isHovered, let content, content.tone != .progress {
      pending = (next, actions)
      return
    }
    apply(next, actions: actions)
  }

  private func apply(_ next: Content, actions: [Action]) {
    self.actions = actions
    // 离开后照旧展开着的那张卡片：换成新的一条就合上，新提示一律从一行出来
    if !isHovered, isExpanded { withAnimation(Self.resize) { isExpanded = false } }
    dwell?.cancel()
    changedAt = .now
    if isOpen, content != nil {
      // 原地更新：内容交叉模糊替换，宽度跟着内容走（spring 0.32）
      withAnimation(Self.resize) { content = next }
    } else {
      open(with: next)
    }
    if next.tone == .error { shakes += 1 }
    onToneChange?(next.tone)
    // VoiceOver 不会去读不当 key 的岛：主动播报
    Self.announce([next.title, next.detail].compactMap { $0 }.joined(separator: "，"))
    // 带按钮的岛多留一会儿：1.4–2 秒来不及挪鼠标去点（G23）
    let seconds: Double =
      switch next.tone {
      case .progress: 60
      case .error: actions.isEmpty ? 3 : 6
      default: actions.isEmpty ? (next.detail == nil ? 1.4 : 2) : 6
      }
    if isHovered {
      remaining = .seconds(seconds)
    } else {
      arm(.seconds(seconds))
    }
  }

  /// 到点收起
  private func arm(_ delay: Duration) {
    dwell?.cancel()
    deadline = .now + delay
    dwell = Task { [weak self] in
      try? await Task.sleep(for: delay)
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
    // 排着还没换上的那条：改它，换上来时就是最新的百分比
    if var queued = pending, queued.content.title == title, queued.content.tone == .progress {
      queued.content.detail = detail
      queued.content.fraction = fraction
      pending = queued
      return
    }
    guard isOpen, let content, content.title == title, content.tone == .progress,
      content.detail != detail || content.fraction != fraction
    else { return }
    // 细条刚出现 / 收掉时宽度变一大截，同原地更新的弹簧；平时只是数字在变，不动画
    withAnimation((content.fraction == nil) != (fraction == nil) ? Self.resize : nil) {
      self.content?.detail = detail
      self.content?.fraction = fraction
    }
    if isHovered { remaining = .seconds(60) } else { arm(.seconds(60)) }
  }

  /// 慢活的「进行中」岛：work 超过 delay 还没做完才出（很快做完的不闪这一下）。做完之后调用方出结果岛就原地换掉它；
  /// 没有结果岛的调用方自己收（dismiss(ifShowing:)）
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

  /// 指针进出岛：进来停住计时、展开、窗口接鼠标；出去接着走剩下的时间（至少 1.5 s），排着的那条这时换上
  func hover(_ inside: Bool) {
    guard inside != isHovered else { return }
    isHovered = inside
    window?.ignoresMouseEvents = !inside
    if inside {
      dwell?.cancel()
      remaining = max(deadline - .now, .zero)
      if !isExpanded {
        changedAt = .now
        withAnimation(Style.Motion.island.animation()) { isExpanded = true }
      }
      hoverCheck = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(200))
          guard let self, !Task.isCancelled else { return }
          self.track()
        }
      }
      return
    }
    hoverCheck?.cancel()
    if let (next, actions) = pending {
      pending = nil
      apply(next, actions: actions)
      return
    }
    if content?.tone == .progress {
      withAnimation(Style.Motion.retract.animation()) { isExpanded = false }
    }
    arm(max(remaining, Self.leaveDelay))
  }

  /// 内容刚换过 / 刚展开（按钮挪了位置）的那一下不算点击
  private var isSettled: Bool {
    guard let changedAt else { return true }
    return ContinuousClock.now - changedAt >= Self.clickGuard
  }

  /// 点岛上的按钮：先收起再跑（跑之前岛已经不在，动作里弹面板不会和岛抢）。排着的那条让给按钮自己的结果：
  /// 按钮没出新提示就换上它，出了就等那条收起再出
  func perform(_ action: Action) {
    guard isSettled else { return }
    let queued = pending
    pending = nil
    dismiss()
    action.run()
    guard let queued else { return }
    if content == nil { apply(queued.content, actions: queued.actions) } else { pending = queued }
  }

  /// 点 ×
  func close() {
    if isSettled { dismiss() }
  }

  /// 收起标题是 title 的这一条（没有结果岛的进行中提示，调用方做完了自己收）：正显示着就收，排着就丢掉
  func dismiss(ifShowing title: String) {
    if pending?.content.title == title { pending = nil }
    if content?.title == title { dismiss() }
  }

  /// 点岛本身：有打开类的按钮就执行它，没有就什么都不做（点得到时已经展开着）
  func tapped() {
    if let open = actions.first(where: \.opens) { perform(open) }
  }

  /// 收起：内容先退（0.12 s），0.08 s 后形体缩回刘海，动画结束再移走窗口。鼠标在岛上时排着一条的（点了 ×、按钮，
  /// 或者调用方自己收），直接换成排着的那条
  func dismiss() {
    dwell?.cancel()
    guard isOpen else { return }
    if let (next, actions) = pending {
      pending = nil
      apply(next, actions: actions)
      return
    }
    hoverCheck?.cancel()
    actions = []
    isHovered = false
    isExpanded = false
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
        self.unwatchMouse()
      }
    }
  }

  /// 双指在岛上往上滑多少算收起（pt，按手指方向）
  static let swipeDistance: CGFloat = 24

  /// 手指往上走了多少：「自然滚动」开着时 scrollingDeltaY 和手指同向（往下为正），关着时相反
  nonisolated static func fingersUp(deltaY: CGFloat, inverted: Bool) -> CGFloat {
    inverted ? -deltaY : deltaY
  }

  private func open(with next: Content) {
    if !isStaged {
      let window = self.window ?? makeWindow()
      self.window = window
      if !isOpen || !window.isVisible { place(window) }
      window.orderFrontRegardless()
      watchMouse()
    }
    content = nil
    // 先让形体从刘海 / 小胶囊长开，内容由自己的过渡晚 60 ms 出场
    withAnimation(Style.Motion.island.animation()) {
      isOpen = true
      content = next
    }
  }

  /// 岛开着时听鼠标移动：别的 App 上的走全局监听，本 App 窗口上的（包括接了鼠标的岛自己）走本地监听。只看位置，
  /// 不吞事件；鼠标移动不要辅助功能授权。指针不动就不算悬停：岛冒在静止的指针下面时，那一下点击照旧落到后面（B6）
  private func watchMouse() {
    guard monitors.isEmpty else { return }
    let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      MainActor.assumeIsolated { self?.track() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      MainActor.assumeIsolated { self?.track() }
    }
    monitors = [local, global].compactMap { $0 }
  }

  private func unwatchMouse() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  // ponytail: 指针停在本 App 不收鼠标移动的窗口（设置窗）上、又正好在岛下面时，本地监听收不到移动，不会展开
  // （离开由 hoverCheck 兜住）；岛在屏幕最顶上，和面板、设置窗叠到的机会很小，真碰到再给那几扇窗口开 acceptsMouseMovedEvents
  private func track() {
    guard content != nil, let window else { return }
    let frame = window.frame
    let shape = CGRect(
      x: frame.minX + shapeFrame.minX, y: frame.maxY - shapeFrame.maxY,
      width: shapeFrame.width, height: shapeFrame.height)
    hover(shape.contains(NSEvent.mouseLocation))
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
    host?.rootView = IslandView(island: self)
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
    // 平时不接鼠标；指针落在形状上才接（hover）。接着的时候指针在岛上移动也要报给本地监听，才知道什么时候出去
    panel.ignoresMouseEvents = true
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    // 宿主包在普通容器里、跟着容器铺满：宿主视图直接当窗口的 contentView 时，SwiftUI 会按内容去改窗口的最小 / 最大
    // 尺寸（光 sizingOptions = [] 不够，同 mac-overlay-panel §1 普通窗口的 windowContent），窗口画过内容之后再改大小
    // （刘海屏和外接屏换着弹、两种窗口不一样高）就在「更新约束」里一圈圈绕下去、抛异常崩掉（2026-10-26 屏上复现；
    // 测试里还见过窗口被它改成 520 × 64）
    let host = IslandHost(rootView: IslandView(island: self))
    host.sizingOptions = []
    host.island = self
    let container = NSView(frame: CGRect(origin: .zero, size: geometry.windowSize))
    host.frame = container.bounds
    host.autoresizingMask = [.width, .height]
    container.addSubview(host)
    panel.contentView = container
    self.host = host
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

/// 几种常用的按钮（拍板 C1 的表）
extension Island.Action {
  /// 打开系统设置里那一项授权（点岛本身也是它）
  static func settings(for kind: Permissions.Kind) -> Self {
    Self("打开系统设置", opens: true) { kind.openSettings() }
  }

  /// 在访达里选中这个文件 / 文件夹（点岛本身也是它）
  static func reveal(_ url: URL) -> Self {
    Self("在访达中显示", opens: true) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
}

extension [Island.Action] {
  /// 存成的文件：在访达中显示（主按钮，点岛也是它）+ 用默认的 App 打开
  static func file(_ url: URL) -> Self {
    [.reveal(url), Island.Action("打开", opens: true) { NSWorkspace.shared.open(url) }]
  }
}

/// 岛的画面：黑色形体（刘海屏带耳朵的下巴 / 其它屏的胶囊）+ 一行内容，悬停时长成卡片
struct IslandView: View {
  let island: Island
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 有内容时的大小：内容先退场、形体再缩回的那一小段里冻住它，免得先跳一下
  @State private var heldSize = CGSize.zero
  /// 收着时那一行多宽：卡片至少这么宽——卡片盖得住那一行，指针不会因为展开被挤到外面（进行中的会来回开合），
  /// 主按钮展开前后也差不多在同一处
  @State private var rowWidth: CGFloat = 0

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
    let held = sized && island.content == nil ? heldSize : .zero
    switch geometry {
    case .notch(let notchWidth, let notchHeight):
      let expanded = island.isExpanded
      content
        .padding(.top, notchHeight)
        // 只设最小尺寸、贴合内容（内容自己限宽）；收起时就是刘海大小
        .frame(
          minWidth: sized ? max(notchWidth + 64, held.width) : notchWidth,
          minHeight: sized ? max(notchHeight + Island.chin, held.height) : notchHeight,
          maxHeight: sized ? .infinity : notchHeight, alignment: .top
        )
        .fixedSize()
        .clipped()
        .background(
          IslandShape(ear: sized ? 10 : 6, bottom: sized ? (expanded ? 24 : 22) : 10)
            .fill(.black)
            .islandShadow(open: open)
        )
        .modifier(Interactive(island: island, held: $heldSize))
        .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
        .opacity(reduceMotion && !open ? 0 : 1)
    case .capsule:
      // 半径 = 收着时的半高：一行时就是胶囊，展开成卡片后是圆角 18 的卡片，同一种形状能连续变
      let shape = RoundedRectangle(cornerRadius: Island.chin / 2, style: .continuous)
      content
        .frame(
          minWidth: max(120, held.width), maxWidth: Island.maxWidth,
          minHeight: max(Island.chin, held.height), alignment: .top
        )
        .fixedSize()
        // 卡片和一行互换时高度差一大截：交叉淡变的半透明字不能画到黑底外面
        .clipShape(shape)
        .background(shape.fill(.black.opacity(0.92)))
        .overlay(shape.hairlineBorder(.white.opacity(0.12)))
        .modifier(Interactive(island: island, held: $heldSize))
        .islandShadow(open: open)
        .scaleEffect(open || reduceMotion ? 1 : 0.6, anchor: .top)
        .opacity(open ? 1 : 0)
        .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
        .padding(.top, 2)
    }
  }

  /// 收着是一行（前导 + 标题 + 详情 + 主按钮），展开是卡片。换内容时模糊交叉替换，首次出场晚 60 ms
  @ViewBuilder private var content: some View {
    ZStack {
      if let content = island.content {
        Group {
          if island.isExpanded {
            card(content).transition(.opacity)
          } else {
            row(content).transition(.opacity)
          }
        }
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

  private func row(_ content: Island.Content) -> some View {
    HStack(spacing: 10) {
      leading(content)
      title(content)
      fractionBar(content)
      if let detail = content.detail {
        Text(detail)
          .font(detailFont(content))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 280, alignment: .leading)
      }
      if let first = island.actions.first {
        IslandButton(title: first.title, prominent: false) { island.perform(first) }
      }
    }
    .frame(height: Island.chin)
    .padding(.horizontal, 18)
    .fixedSize(horizontal: true, vertical: false)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { width in
      rowWidth = width
    }
  }

  /// 展开的卡片：第一行和收着时同高，按钮（主按钮在最右）和 × 在这一行；完整详情折在下面，最多 4 行。
  /// 宽度按第一行和详情排成一行的长度取大的，至少和收着时那一行一样宽、最宽 460
  private func card(_ content: Island.Content) -> some View {
    CardLayout(minWidth: rowWidth - 36, maxWidth: Island.maxWidth - 36) {
      HStack(spacing: 10) {
        leading(content)
        title(content)
        fractionBar(content)
        Spacer(minLength: 12)
        HStack(spacing: 8) {
          ForEach(Array(island.actions.enumerated().reversed()), id: \.offset) { index, action in
            IslandButton(title: action.title, prominent: index == 0) { island.perform(action) }
          }
          Button {
            island.close()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.white.opacity(0.8))
              .frame(width: 20, height: 20)
              .background(Circle().fill(.white.opacity(0.16)))
          }
          .buttonStyle(IslandButtonStyle())
          .accessibilityLabel("关闭")
        }
      }
      .frame(height: Island.chin)
      if let detail = content.detail {
        Text(detail)
          .font(detailFont(content))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 32)
          .padding(.bottom, 12)
      }
    }
    .padding(.horizontal, 18)
  }

  private func title(_ content: Island.Content) -> some View {
    Text(content.title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white.opacity(0.95))
      .lineLimit(1)
  }

  /// 进行中的详情是会变的百分比：数字等宽，岛不跟着一宽一窄地抖
  private func detailFont(_ content: Island.Content) -> Font {
    content.tone == .progress ? .system(size: 13).monospacedDigit() : .system(size: 13)
  }

  @ViewBuilder private func fractionBar(_ content: Island.Content) -> some View {
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

/// 形状这一层：量出它在窗口里的位置报给岛（判断指针在不在岛上），有内容时记下大小（收起时冻住）；点岛本身走 tapped
private struct Interactive: ViewModifier {
  let island: Island
  @Binding var held: CGSize

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture { island.tapped() }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: { frame in
        island.shapeFrame = frame
        if island.content != nil { held = frame.size }
      }
  }
}

/// 岛上的胶囊按钮：12 semibold、高约 22；主按钮（展开后最右那个）白底黑字，其余 white 0.16 底白字
private struct IslandButton: View {
  let title: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(prominent ? .black : .white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(.white.opacity(prominent ? 0.92 : 0.16)))
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(title)
  }
}

/// 按下缩到 0.96、淡一点（不当 key 的窗口里 SwiftUI 的悬停不可靠，不做悬停底）
private struct IslandButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

/// 卡片的排法：宽度取各行排成一行时最长的那个（夹到 minWidth…maxWidth，往上取整：正好等于理想宽度时取整会把按钮挤成「…」），
/// 每一行在这个宽度里排、详情折行
/// nonisolated：Layout 是非隔离协议，纯几何计算
nonisolated private struct CardLayout: Layout {
  var minWidth: CGFloat
  var maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = cardWidth(subviews)
    let height = subviews.reduce(0) {
      $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for subview in subviews {
      let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
      subview.place(
        at: CGPoint(x: bounds.minX, y: y),
        proposal: ProposedViewSize(width: bounds.width, height: height))
      y += height
    }
  }

  private func cardWidth(_ subviews: Subviews) -> CGFloat {
    let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    return min(max(widest.rounded(.up), minWidth), maxWidth)
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

/// 岛的宿主：接着鼠标时第一下点击就给按钮（本 App 不在前台时也一样，G23）；指针在岛上时双指往上滑收起。
/// 平时窗口整个不接鼠标，这两样都不起作用
private final class IslandHost: NSHostingView<IslandView> {
  weak var island: Island?
  /// 这一次手势里手指往上走了多少；够了收一次，同一次手势不再算
  private var swipe: CGFloat = 0

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func scrollWheel(with event: NSEvent) {
    // 只认触控板的手势阶段（鼠标滚轮、惯性阶段的 phase 是空的）
    guard event.phase != [] else { return }
    if event.phase == .began { swipe = 0 }
    guard swipe < Island.swipeDistance else { return }
    swipe += Island.fingersUp(
      deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice)
    if swipe >= Island.swipeDistance { island?.dismiss() }
  }
}
