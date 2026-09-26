// CleanShot 式常驻缩略图（Whisker D8）：截图飞到右下角、角标弹完以后由这里接手，留在原地（同一个位置、同样的圆角阴影）。
// 悬停时出 HUD 操作：中间「拷贝」「存储」两个胶囊，左上关闭、右上钉图，存过的左下「在访达中显示」；
// 拖出去是一个 PNG 文件（拖进访达、邮件、聊天窗口），双击用默认 App 打开；触控板往右轻扫就滑走；
// 鼠标不在上面时 6 s 后自己滑走（移开后 2.5 s）。同一块屏上连截几张时往上叠，最多 3 张，更早的滑走。
// 窗口是普通 NSPanel 实例（不当 key、不激活本 App；层级状态栏，之后的截图冻结帧会排除它），用完放回复用池
// （挂过 NSHostingView 的窗口 close 后 AppKit 不释放，同 FlyCard）。减弱动态效果时不飞，直接在角落淡入、淡出。

import AppKit
import SwiftUI

final class ShotShelf {
  /// 再拷贝一次 / 快速保存 / 钉到原来的位置（AppDelegate 给）
  var copy: (CGImage, CGFloat) async -> Bool = { _, _ in false }
  var save: (CGImage, CGFloat) async -> URL? = { _, _ in nil }
  var pin: (CGImage, CGRect) -> Void = { _, _ in }

  private var cards: [ShelfCard] = []
  private var idle: [NSPanel] = []
  /// 卡片四周给阴影留的边（窗口比卡片大这么多）
  static let margin: CGFloat = 24
  private static let gap: CGFloat = 10
  private static let maxPerScreen = 3
  /// 拖出去用的 PNG 放在这里；启动时清空（拖进邮件、聊天的附件可能还在读，用的时候不删）
  static let dragDirectory = FileManager.default.temporaryDirectory.appending(
    path: "Kitty Tools 截图")

  /// 接手一张截图：rect 是落地位置（屏幕坐标），source 是选区（钉图钉回那里）
  func add(
    _ image: CGImage, scale: CGFloat, source: CGRect, at rect: CGRect, badge: FlyCard.Badge
  ) {
    let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
    // 同一块屏上已有的往上挪给新的让位；超过 3 张的最早那张滑走
    let neighbours = cards.filter { !$0.isLeaving && $0.screen == screen }
    for card in neighbours { card.shift(by: rect.height + Self.gap) }
    if neighbours.count >= Self.maxPerScreen, let oldest = neighbours.first { dismiss(oldest) }
    let card = ShelfCard(
      image: image, scale: scale, source: source, rect: rect, badge: badge, screen: screen,
      panel: idle.popLast() ?? Self.makePanel(), shelf: self)
    cards.append(card)
    card.show()
  }

  func dismiss(_ card: ShelfCard) {
    guard !card.isLeaving else { return }
    card.isLeaving = true
    // 在它上面的往下落回来
    for other in cards
    where !other.isLeaving && other.screen == card.screen
      && other.rect.minY > card.rect.minY
    {
      other.shift(by: -(card.rect.height + Self.gap))
    }
    card.slideOut { [weak self, weak card] in
      guard let self, let card else { return }
      cards.removeAll { $0 === card }
      let panel = card.panel
      panel.close()
      // 下一轮再拆视图：别在它自己的 SwiftUI 任务里把它释放
      Task {
        panel.contentView = nil
        self.idle.append(panel)
      }
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.animationBehavior = .none
    panel.isReleasedWhenClosed = false
    panel.becomesKeyOnlyIfNeeded = true
    return panel
  }
}

/// 一张常驻缩略图：窗口、界面状态、自动滑走的计时
@Observable final class ShelfCard {
  let image: CGImage
  /// 显示的部分（长截图只露开头一屏）
  let shown: CGImage
  let scale: CGFloat
  let source: CGRect
  @ObservationIgnored let screen: NSScreen?
  @ObservationIgnored let panel: NSPanel
  @ObservationIgnored private weak var shelf: ShotShelf?
  /// 卡片的屏幕位置（不含阴影边）
  @ObservationIgnored private(set) var rect: CGRect
  @ObservationIgnored var isLeaving = false
  var badge: FlyCard.Badge
  var isHovered = false { didSet { isHovered ? timer?.cancel() : scheduleDismiss(after: 2.5) } }
  /// 正在拷贝 / 保存（按钮转圈）
  var isBusy = false
  /// 拖出去用的文件：存过就是存的那个，否则是临时目录里编码好的 PNG
  @ObservationIgnored private(set) var fileURL: URL?
  @ObservationIgnored private var timer: Task<Void, Never>?
  /// 触控板横扫时跟手的偏移
  @ObservationIgnored private var swipe: CGFloat = 0

  init(
    image: CGImage, scale: CGFloat, source: CGRect, rect: CGRect, badge: FlyCard.Badge,
    screen: NSScreen?, panel: NSPanel, shelf: ShotShelf
  ) {
    self.image = image
    shown = FlyCard.visiblePart(of: image, frame: source)
    self.scale = scale
    self.source = source
    self.rect = rect
    self.badge = badge
    self.screen = screen
    self.panel = panel
    self.shelf = shelf
    if case .saved(let url) = badge { fileURL = url }
  }

  func show() {
    let host = ShelfHostingView(rootView: ShelfCardView(card: self))
    host.sizingOptions = []
    host.onHover = { [weak self] in self?.isHovered = $0 }
    host.onSwipe = { [weak self] delta, ended in self?.swiped(delta, ended: ended) }
    panel.contentView = host
    panel.setFrame(rect.insetBy(dx: -ShotShelf.margin, dy: -ShotShelf.margin), display: false)
    // 飞行卡片刚在同一个位置关掉：直接出现就接上了；减弱动态效果时（没有飞）淡入
    panel.alphaValue = Style.reduceMotion ? 0 : 1
    panel.orderFrontRegardless()
    if Style.reduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 1
      }
    }
    scheduleDismiss(after: 6)
    if fileURL == nil { Task { await writeDragFile() } }
  }

  /// 往上 / 往下挪（叠放让位），glide 的近似
  func shift(by dy: CGFloat) {
    rect.origin.y += dy
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.reduceMotion ? 0 : 0.26
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
      panel.animator().setFrame(
        rect.insetBy(dx: -ShotShelf.margin, dy: -ShotShelf.margin), display: true)
    }
  }

  /// 向右滑出屏幕（0.28 s easeIn）；减弱动态效果时原地淡出
  func slideOut(completion: @escaping @MainActor @Sendable () -> Void) {
    timer?.cancel()
    let exit = (screen?.frame.maxX ?? rect.maxX) - rect.minX + ShotShelf.margin + 10
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.reduceMotion ? 0.2 : 0.28
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      if Style.reduceMotion {
        panel.animator().alphaValue = 0
      } else {
        panel.animator().setFrameOrigin(
          CGPoint(x: panel.frame.minX + exit, y: panel.frame.minY))
      }
    } completionHandler: {
      MainActor.assumeIsolated(completion)
    }
  }

  // MARK: 操作

  func close() { shelf?.dismiss(self) }

  func copyAgain() {
    guard !isBusy, let shelf else { return }
    isBusy = true
    Task {
      if await shelf.copy(image, scale) { badge = .copied }
      isBusy = false
    }
  }

  func save() {
    guard !isBusy, let shelf else { return }
    isBusy = true
    Task {
      if let url = await shelf.save(image, scale) {
        badge = .saved(url)
        fileURL = url
      }
      isBusy = false
    }
  }

  func pin() {
    shelf?.pin(image, source)
    close()
  }

  func revealInFinder() {
    if case .saved(let url) = badge { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }

  func open() {
    if let fileURL { NSWorkspace.shared.open(fileURL) }
  }

  /// 拖出去的东西：文件（还没编码好时给一张图）
  func dragItem() -> NSItemProvider {
    if let fileURL, let provider = NSItemProvider(contentsOf: fileURL) { return provider }
    return NSItemProvider(object: NSImage(cgImage: image, size: .zero))
  }

  private func writeDragFile() async {
    guard let png = await ScreenshotOutput.png(image, scale: scale) else { return }
    try? FileManager.default.createDirectory(
      at: ShotShelf.dragDirectory, withIntermediateDirectories: true)
    let url = ScreenshotOutput.availableURL(in: ShotShelf.dragDirectory)
    guard (try? png.write(to: url)) != nil, fileURL == nil else { return }
    fileURL = url
  }

  private func scheduleDismiss(after seconds: Double) {
    timer?.cancel()
    guard !isLeaving else { return }
    timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self, !self.isHovered else { return }
      self.close()
    }
  }

  /// 触控板横扫：卡片跟着手指往右走（往左不动），松手时过了 50 pt 就滑走，否则弹回
  private func swiped(_ delta: CGFloat, ended: Bool) {
    guard !isLeaving else { return }
    swipe = max(0, swipe + delta)
    let base = rect.minX - ShotShelf.margin
    if ended {
      if swipe > 50 { return close() }
      swipe = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Style.reduceMotion ? 0 : 0.26
        panel.animator().setFrameOrigin(CGPoint(x: base, y: panel.frame.minY))
      }
    } else {
      panel.setFrameOrigin(CGPoint(x: base + swipe, y: panel.frame.minY))
    }
  }
}

/// 缩略图的宿主：本 App 不激活，SwiftUI 的悬停和光标跟踪不可靠，用 activeAlways 追踪区自己报悬停；
/// 第一下点击就给按钮；触控板横扫转给卡片
private final class ShelfHostingView: NSHostingView<ShelfCardView> {
  var onHover: (Bool) -> Void = { _ in }
  var onSwipe: (CGFloat, Bool) -> Void = { _, _ in }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds.insetBy(dx: ShotShelf.margin, dy: ShotShelf.margin),
        options: [.activeAlways, .mouseEnteredAndExited], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onHover(true) }
  override func mouseExited(with event: NSEvent) { onHover(false) }

  /// 手指往右的距离：「自然滚动」开着时 scrollingDeltaX 和手指同向，关着时相反
  override func scrollWheel(with event: NSEvent) {
    // 只跟触控板的手势阶段（惯性阶段、鼠标滚轮的 phase 都是空的，不跟）
    guard event.phase != [] else { return }
    let fingers =
      event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
    onSwipe(fingers, event.phase == .ended || event.phase == .cancelled)
  }
}

struct ShelfCardView: View {
  let card: ShelfCard
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    // 图放在 overlay 里铺满：fill 的图不参与布局，比例和卡片不一样时也不会把卡片撑大
    Color.clear
      .overlay {
        Image(decorative: card.shown, scale: 1).resizable().aspectRatio(contentMode: .fill)
      }
      .overlay {
        if card.isHovered {
          ZStack {
            Color.black.opacity(0.35)
            actions
          }
          .transition(.opacity)
        }
      }
      .clipShape(shape)
      .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
      .overlay(alignment: .bottomTrailing) {
        FlyCardBadge(badge: card.badge)
          .offset(x: 6, y: 6)
          .id(card.badge.folder ?? "copied")
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      }
      .animation(Style.Motion.pop.animation(reduced: reduceMotion), value: card.badge.folder)
      .animation(.easeOut(duration: 0.12), value: card.isHovered)
      .onDrag { card.dragItem() }
      .onTapGesture(count: 2) { card.open() }
      .padding(ShotShelf.margin)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("截图缩略图")
  }

  /// 中间拷贝 / 存储；四角关闭、钉图、在访达中显示。卡片矮的时候胶囊只留图标
  private var actions: some View {
    GeometryReader { geometry in
      let compact = geometry.size.height < 90 || geometry.size.width < 150
      ZStack {
        HStack(spacing: 6) {
          pill("拷贝", "doc.on.doc", compact: compact, action: card.copyAgain)
          pill("存储", "square.and.arrow.down", compact: compact, action: card.save)
        }
        .opacity(card.isBusy ? 0.5 : 1)
        .overlay { if card.isBusy { ProgressView().controlSize(.small).tint(.white) } }
        round("xmark", "关闭", action: card.close).frame(
          maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        round("pin.fill", "钉图", action: card.pin).frame(
          maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        if case .saved = card.badge {
          round("folder", "在访达中显示", action: card.revealInFinder).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
      }
      .padding(6)
    }
  }

  private func pill(
    _ title: String, _ symbol: String, compact: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
        if !compact { Text(title) }
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.white.opacity(0.95))
      .padding(.horizontal, compact ? 7 : 10)
      .frame(height: 26)
      .background(.black.opacity(0.55), in: .capsule)
      .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
      .contentShape(.capsule)
    }
    .buttonStyle(PressScale())
    .disabled(card.isBusy)
    .help(title)
  }

  private func round(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white.opacity(0.95))
        .frame(width: 22, height: 22)
        .background(.black.opacity(0.55), in: .circle)
        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .contentShape(.circle)
    }
    .buttonStyle(PressScale())
    .help(title)
    .accessibilityLabel(title)
  }
}
