// 刘海岛听刘海和鼠标（第五轮体检 H1 从 Island.swift 拆出）：启动时建窗口、屏幕变了重算刘海，点刘海 / 停在刘海上鼓起、停一下自动展开，鼠标在形状上才接事件。

import AppKit
import OSLog
import SwiftUI

extension Island {
  /// 开始听刘海（AppDelegate 启动后调一次）：指针停在刘海上鼓起一点，点刘海打开 / 收起那一张。监听从此一直装着
  /// （只看位置、不吞事件；鼠标移动和点击都不要授权）
  func start() {
    updateNotches()
    prepareWindow()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateNotches() }
    }
    spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.verifyOnScreen(again: true) }
    }
  }

  /// 刘海屏的 Mac：启动时先把窗口建好、按刘海屏收着的样子排一遍（不显示）——第一次停到刘海上就有现成的窗口和
  /// 动画的起点，也不用在那一下当场建窗口
  private func prepareWindow() {
    guard !isStaged, window == nil,
      let screen = NSScreen.screens.first(where: { Self.notchRect(of: $0) != nil })
    else { return }
    geometry = Self.geometry(of: screen)
    let window = makeWindow()
    self.window = window
    host?.rootView = IslandView(island: self)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// 屏幕变了（接上 / 拔掉外接屏、合盖、改分辨率）：重算刘海在哪；没有刘海屏就不常驻监听。
  /// 每块屏的几何写进日志（`log show --predicate 'category == "island"'`）：新机型我们没有真机，靠用户发来这几行
  private func updateNotches() {
    for screen in NSScreen.screens {
      let kind =
        Self.hasSystemIsland(screen)
        ? "系统灵动岛" : Self.notchRect(of: screen) == nil ? "胶囊" : "刘海"
      Log.island.notice(
        "\(screen.localizedName, privacy: .public)：\(kind, privacy: .public)，frame \(screen.frame.debugDescription, privacy: .public)，菜单栏 \(Double(screen.frame.maxY - screen.visibleFrame.maxY))，安全区顶 \(Double(screen.safeAreaInsets.top))，辅助区 \((screen.auxiliaryTopLeftArea ?? .zero).debugDescription, privacy: .public) / \((screen.auxiliaryTopRightArea ?? .zero).debugDescription, privacy: .public)"
      )
    }
    notchRects = NSScreen.screens.compactMap(Self.notchRect(of:))
    rewatchNotch()
    // 合盖只用外接屏、又打开：耳朵跟着收掉 / 长回来
    refreshWings()
    // 耳朵露着、没展开（放歌、录制、保持唤醒挂一整天的那种）：按现在的刘海屏重摆一次——改了「更多空间」这类缩放、接上
    // 外接屏让内建屏的坐标变了，刘海的位置和宽高都可能变，窗口不挪的话耳朵就不对着真刘海（第五轮体检 E12）。
    // 展开着的（提示、卡片、那一张）不动：内容正在屏上，当场挪会跳一下
    // ponytail: 展开期间换了屏的，收起后缩回耳朵时不重摆（要等耳朵收掉、下一次长出来，或者下一次换屏）；真碰到再在
    // dismiss 缩回耳朵那一步补一次 place
    if isShowingWings, !isOpen, !isStaged, let window, let screen = Self.notchScreen {
      place(window, on: screen)
    }
    // 挂着的提醒（边框亮着时能关它的只有这张卡）：原来那块屏拔掉了、合上了，挪到指针那块屏上（issue #51）
    followPointer()
    // 屏幕一变，窗口可能就掉出了所有桌面（issue #55，报告人是切过外接屏之后）：没显示着的直接换一扇新的（同启动时，
    // 下一次停到刘海上用新的），显示着的查一下
    if let window, !window.isVisible, !isStaged {
      window.close()
      self.window = nil
      prepareWindow()
    } else {
      verifyOnScreen(again: true)
    }
  }

  /// 岛的窗口真的在当前桌面上吗（issue #55）。设了 .canJoinAllSpaces 的窗口，窗口服务器有时会丢掉它「所有桌面」的归属、
  /// 只留在一个桌面上：报告人（15.7.4、台前调度、6 个桌面）切过外接屏之后，窗口服务器里岛的窗口只属于一个 Space，
  /// orderFrontRegardless 只是在那个桌面里拿到前面，别的桌面上停在刘海上、点刘海都没反应。GitHub 上别的项目记过同样的事
  /// （有一家说退出全屏空间的那一刻窗口正被排下去就会这样），起因没有公开的说法；重设 collectionBehavior、排下去再排上来
  /// 都救不回来，只有换一扇新窗口能救（别家实测）。岛的窗口整个进程只建一次、每次收起都排下去，坏了就一直坏到重启——
  /// issue #51「边框亮着、刘海上的提醒卡没出来」也是它：边框是到点新建的窗口，每个桌面上都在。
  /// 所以排上去之后（showWindow）、换了桌面、屏幕变了时过 0.3 s 问一次窗口服务器，不在就再等 0.3 s 问一次（排上去那一拍
  /// 可能还没交给它、换桌面的动画可能还没走完），还不在就换一扇新的（rebuildWindow）。
  /// again：换桌面、屏幕变了——正在查的那一次作废、从头查（不然查的是换之前的样子）；showWindow 来的正在查就不重来
  /// （内容一换就调一次，进度条这类连着换的会让它一直查不完）
  func verifyOnScreen(again: Bool = false) {
    if again {
      spaceCheck?.cancel()
      spaceCheck = nil
    }
    guard spaceCheck == nil, !isStaged, let watched = window, watched.isVisible else { return }
    spaceCheck = Task { [weak self] in
      let lost = await Self.stillLost(watched)
      guard !Task.isCancelled, let self else { return }
      self.spaceCheck = nil
      if lost, self.window === watched { self.rebuildWindow() }
    }
  }

  /// 查一次的间隔
  static let spaceCheckDelay = Duration.milliseconds(300)
  /// 换过一次窗口之后多久内不再换（换了还不在：调度中心开着这类窗口服务器本来就不给看的时候，不来回换）
  static let rebuildGap = Duration.seconds(10)

  /// 隔 spaceCheckDelay 问两次，两次都说掉出了当前桌面才算
  private static func stillLost(_ window: NSWindow) async -> Bool {
    for _ in 0..<2 {
      try? await Task.sleep(for: spaceCheckDelay)
      guard !Task.isCancelled,
        IslandFullScreen.lostSpace(
          visible: window.isVisible, onScreen: IslandFullScreen.isOnScreen(window.windowNumber),
          hasScreens: !NSScreen.screens.isEmpty)
      else { return false }
    }
    return true
  }

  /// 换一扇新窗口顶上（issue #55）：新窗口排上去时窗口服务器重新把它放进所有桌面。旧的排下去关掉，内容、接不接鼠标照旧
  /// （新窗口的内容直接画成现在的样子，没有长出来的动画）。键盘在它上面时（快捷键叫出的那一张、交给按钮的键盘）不换，
  /// 收起后下一次显示再查
  // ponytail: 只能事后救（掉出去的那一次最多晚 0.6 s 出现）；要从根上避开得改成收起时不排下去（透明度 0 留在屏上），
  // 那要重新量窗口常驻的内存、点穿和截图里会不会带上，等这个救法不够再说
  private func rebuildWindow() {
    guard let old = window, !holdsKeyboard else { return }
    let now = ContinuousClock.now
    if let rebuiltAt, now - rebuiltAt < Self.rebuildGap {
      Log.island.error("岛的窗口换过一扇还是不在当前桌面上")
      return
    }
    rebuiltAt = now
    Log.island.notice("岛的窗口不在当前桌面上，换一扇新的")
    let ignoresMouse = old.ignoresMouseEvents
    let screen = old.screen
    old.orderOut(nil)
    old.close()
    window = nil
    showWindow(on: screen)
    window?.ignoresMouseEvents = ignoresMouse
    syncBackdrop()
  }

  /// 有刘海屏、插件也添加着才常驻监听（点刘海、停在刘海上、耳朵的悬停要它们）；否则照旧显示时装、收起后卸
  func rewatchNotch() {
    watchesNotch = hasExtras && !notchRects.isEmpty
    if watchesNotch { watchMouse() } else if !isOpen { unwatchMouse() }
  }

  /// 硬件刘海在屏幕上的那一块（屏幕坐标）；没有刘海的屏是 nil
  static func notchRect(of screen: NSScreen) -> CGRect? {
    guard case .notch(let width, let height) = geometry(of: screen) else { return nil }
    return CGRect(
      x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
  }

  /// 指针在不在某块刘海上：只认刘海本身（鼓起那一圈是画出来的样子，不算——离刘海最近的菜单栏项可能就在那一圈里），
  /// 按指针的算法含屏幕最顶那一行、不往上越过顶边（上面摆着的外接屏底边那一条不算）
  static func onNotch(_ point: CGPoint, notches: [CGRect]) -> Bool {
    notches.contains { NSMouseInRect(point, $0, false) }
  }

  /// 听鼠标：别的 App 上的走全局监听，本 App 窗口上的（包括接了鼠标的岛自己）走本地监听。只看位置，不吞事件；
  /// 鼠标移动和点击都不要辅助功能授权。指针不动就不算悬停：岛冒在静止的指针下面时，那一下点击照旧落到后面（B6）
  func watchMouse() {
    guard monitors.isEmpty else { return }
    let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown]
    let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      let swallow = MainActor.assumeIsolated { self?.handle(event, local: true) ?? false }
      return swallow ? nil : event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      _ = MainActor.assumeIsolated { self?.handle(event, local: false) }
    }
    monitors = [local, global].compactMap { $0 }
  }

  /// 一个鼠标事件；返回本地监听要不要吞掉它：落在岛自己窗口上、已经当成开 / 关那一张处理掉的那一下吞掉（不然它接着发给岛，
  /// 从鼓起点开时窗口刚加高，按旧位置会点中列表里的某一行）
  private func handle(_ event: NSEvent, local: Bool) -> Bool {
    guard event.type == .leftMouseDown else {
      track()
      return false
    }
    // 本 App 别的窗口盖着刘海时（截图遮罩、启动台），点在它们上面不算点刘海；双击只认第一下
    let ownsClick = !local || event.window == nil || event.window === window
    let toggled = click(onNotch: ownsClick, repeated: event.clickCount > 1)
    return toggled && local && event.window === window
  }

  /// 点了一下：点在刘海上 = 没开着东西时打开（openTop：有活动是它的卡片，没有是那一张）、那一张开着时收起、活动的卡片
  /// 开着时轮到下一个（rotate）；别的提示开着时不管（屏幕最顶那一行窗口收不到点击，全局监听收得到）。
  /// 那一张、活动的卡片（播放卡片没有 ×）开着时点在它外面 = 收起。返回这一下处理掉了没有（本地监听据此吞掉它）。
  /// repeated：双击的第二、三下——不算点刘海（不然开了又关、连轮两个）；卡片开着时照样吞掉，别落到卡片上被当成
  /// 点它的打开类按钮（tapped，评审 3）
  private func click(onNotch allowed: Bool, repeated: Bool = false) -> Bool {
    let mouse = NSEvent.mouseLocation
    if allowed, respondsToNotch, !isSuppressed(), Self.onNotch(mouse, notches: notchRects) {
      if repeated {
        if content != nil, cardActivity != nil { return true }
      } else {
        switch Self.notchClick(
          hasContent: content != nil, boardOpen: isBoardOpen, cardOpen: cardActivity != nil)
        {
        case .open:
          presses += 1
          openTop()
          return true
        case .closeBoard:
          presses += 1
          toggleBoard()
          return true
        case .rotate:
          // 刚换过面时不轮（rotate 自己挡），这一下照样吞掉
          presses += 1
          rotate()
          return true
        case .ignore: break
        }
      }
    }
    if isBoardOpen || (content != nil && cardActivity != nil), let window,
      !NSMouseInRect(mouse, shapeOnScreen(window), false)
    {
      dismiss()
    }
    return false
  }

  /// 指针停在刘海上（没有提示、没开那一张）：鼓起一点，窗口这时接住点击；离开就缩回、移走窗口
  /// 鼓起 / 缩回的曲线由 IslandView 定（鼓起 0.2 s easeOut，缩回同收起）
  private func peek(_ on: Bool) {
    guard on != isPeeking, !isStaged else { return }
    if on {
      // 先摆好窗口（新建的先按收着的样子排一遍），再鼓：顺序反了第一次鼓起没有动画
      showWindow()
      window?.ignoresMouseEvents = false
      isPeeking = true
      return
    }
    isPeeking = false
    hoverExpand?.cancel()
    hoverExpand = nil
    window?.ignoresMouseEvents = true
    Task { [weak self] in
      try? await Task.sleep(for: Self.retractTime)
      guard let self, !self.isOpen, !self.isPeeking, !self.isShowingWings else { return }
      self.window?.orderOut(nil)
    }
  }

  enum NotchClick { case open, closeBoard, rotate, ignore }

  /// 点在刘海上该做什么（纯函数）：那一张开着 = 收起；什么都没开 = 打开；活动的卡片开着 = 轮到下一个；别的提示开着不管
  static func notchClick(hasContent: Bool, boardOpen: Bool, cardOpen: Bool) -> NotchClick {
    if boardOpen { return .closeBoard }
    if !hasContent { return .open }
    return cardOpen ? .rotate : .ignore
  }

  /// 停在耳朵 / 刘海上多久自动展开
  static let hoverExpandDelay = Duration.milliseconds(300)

  /// 指针在鼓起的岛上：排「停一下自动展开」（C1）。只在有活动露着时（没有活动时悬停只鼓起、点了才开那一张）；刘海
  /// 正中和两只耳朵都算（2026-11-14：原来刘海正中不算，点它出的是另一张面）；正在播放的右耳是播放 / 暂停钮，停在它
  /// 上面不展开（不然正要点，卡片先盖上来）。到点时还鼓着、岛上没别的东西、没在框选才展开；展开后当指针在岛上（它就停在那儿，没有鼠标移动来报）：
  /// 不然窗口不接鼠标、卡片照没人看的提示 2 秒就收
  private func armHoverExpand(_ mouse: NSPoint) {
    guard hoverExpands, isPeeking, content == nil, !isBoardOpen, let top = activity, let window,
      Self.hoverExpands(
        pointerX: mouse.x, shape: shapeOnScreen(window), onMedia: top.media != nil,
        notch: respondsToNotch)
    else {
      hoverExpand?.cancel()
      hoverExpand = nil
      return
    }
    guard hoverExpand == nil else { return }
    let delay = hoverDelay
    hoverExpand = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      self.hoverExpand = nil
      guard self.isPeeking, self.content == nil, !self.isBoardOpen, !self.isSuppressed() else {
        return
      }
      self.expandActivity()
      self.hover(true)
    }
  }

  /// 指针在这个横坐标上停着算不算要展开（纯函数）：左耳算；右耳算，除非是正在播放（那一截是播放 / 暂停钮）；中间的
  /// 刘海也算，除非设置里关了「点刘海打开」（notch）。耳朵 = 形体两头往里一只耳朵宽（另加鼓起的那一圈 8 pt）
  static func hoverExpands(pointerX: CGFloat, shape: CGRect, onMedia: Bool, notch: Bool = true)
    -> Bool
  {
    if pointerX > shape.maxX - wing - 8 { return !onMedia }
    return pointerX < shape.minX + wing + 8 || notch
  }

  private func shapeOnScreen(_ window: NSWindow) -> CGRect {
    let frame = window.frame
    return CGRect(
      x: frame.minX + shapeFrame.minX, y: frame.maxY - shapeFrame.maxY,
      width: shapeFrame.width, height: shapeFrame.height)
  }

  func unwatchMouse() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  // ponytail: 指针停在本 App 不收鼠标移动的窗口（设置窗）上、又正好在岛下面时，本地监听收不到移动，不会展开
  // （离开由 hoverCheck 兜住）；岛在屏幕最顶上，和面板、设置窗叠到的机会很小，真碰到再给那几扇窗口开 acceptsMouseMovedEvents
  func track() {
    // 拖着时不算进出。兜底：松手那一下没送到窗口（拖着时锁屏、切桌面）就照按键的实际状态放开，不然卡片永远不收
    if isDragging, NSEvent.pressedMouseButtons & 1 == 0 { isDragging = false }
    guard !isDragging else { return }
    // 全屏时藏着：不接鼠标（不然看不见的岛会吞掉全屏时滑下来的菜单栏上的点击）
    if hidesNow { return }
    let mouse = NSEvent.mouseLocation
    // 音量 / 亮度的提示上没有能点的东西：不算悬停（不停计时、窗口不接鼠标，底下的菜单栏照常点）
    if isShowingLevel { return }
    if content != nil || isBoardOpen {
      if let window { hover(NSMouseInRect(mouse, shapeOnScreen(window), false)) }
      // 挂着的提醒跟着指针换屏（issue #51）
      followPointer()
      return
    }
    // 刚收起、还在缩回时不鼓
    guard !isOpen, !isRetracting else { return }
    let onWings =
      isShowingWings && window.map { NSMouseInRect(mouse, shapeOnScreen($0), false) } == true
    peek(
      !isSuppressed() && (onWings || (respondsToNotch && Self.onNotch(mouse, notches: notchRects))))
    armHoverExpand(mouse)
  }
}
