// 设置里的悬停预览（2026-11-18 设置改版 S10，规格 SPEC §6）：停在几行有演示的设置上，舞台上用缩小的真界面演它的效果
// （照系统设置 › 鼠标 / 触控板停在一行上的动画，但不用视频）。舞台 = 一块 120 高的小桌面（外观缩略图那张壁纸 + 顶上 7 pt 的
// 菜单栏），放在那一组的第一行之上、跟着表单一起滚；没停在任何一行上时画这一页的静止帧（当前设置下演完的样子）。
// 刘海岛页和它的正在播放 / 日程与月历 / 音量与亮度三个子页例外（2026-11-20，0.10.1 用户反馈）：演示的行散在整页，跟着
// 表单滚的舞台在停到「活动」那几行时早就滚出去了，所以钉在页头下面（pinned()），表单在它下面滚；设置窗最矮时下面还露四五行。
// 首批三个场景：截完图放哪（截图页）、呼出面板时挤压弹开（通用 › 高级）、刘海岛的点刘海 / 自动展开 / 正在播放 / 日程 / 音量。
// 规矩：只在有行被停着时演（.task 跟着停着的那一行，离开就取消、回到静止帧，不另起定时器）；减弱动态效果时只给静止的一帧；
// 读屏整块藏起来（装饰，行的副标题已经说了效果）；舞台里的一切是摆出来的——刘海岛用「摆出来的岛」Island(showing:…)：
// 不建窗口、不给触感、不读本机状态，不放声音、不写偏好、不接点击。

import SwiftUI

/// 有演示的几行
enum PreviewScene: Equatable {
  /// 截完图放哪（截图页）
  case placement
  /// 呼出面板时挤压弹开（通用 › 高级）
  case squeeze
  /// 刘海岛页：点刘海打开、停在刘海上自动展开、正在播放、日程与月历、音量与亮度
  case notchClick, hoverExpand, nowPlaying, calendar, levels
}

/// 这一页停着的是哪一行：进来马上换，出去 0.3 s 后才回到静止帧（行和行之间滑过不闪）
@Observable final class PreviewFocus {
  private(set) var scene: PreviewScene?
  @ObservationIgnored private var leaving: Task<Void, Never>?

  func enter(_ scene: PreviewScene) {
    leaving?.cancel()
    if self.scene != scene { self.scene = scene }
  }

  func leave(_ scene: PreviewScene) {
    leaving?.cancel()
    leaving = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self, self.scene == scene else { return }
      self.scene = nil
    }
  }
}

extension View {
  /// 这一行有演示：指针停上去时舞台演它（同一页的 PreviewStage 读同一个 PreviewFocus）。
  /// ponytail: 只认指针；键盘焦点落在这一行的控件上也演，要给每种控件挂 @FocusState，等有人要再加
  func previews(_ scene: PreviewScene) -> some View { modifier(PreviewHover(scene: scene)) }
}

private struct PreviewHover: ViewModifier {
  let scene: PreviewScene
  @Environment(PreviewFocus.self) private var focus: PreviewFocus?

  func body(content: Content) -> some View {
    content
      .onHover { inside in
        if inside { focus?.enter(scene) } else { focus?.leave(scene) }
      }
      // 停着时行被推走（点进推进行、关掉表单）不会补一个 onHover(false)：消失也算离开
      .onDisappear { focus?.leave(scene) }
  }
}

/// 舞台：一块小桌面，演停着的那一行（没停着时画 still 这个场景的最后一帧）
struct PreviewStage: View {
  /// 没停在任何一行上时画哪个场景
  let still: PreviewScene
  /// 截图自检摆一个场景的某一步（不演）；nil = 正常（跟着停着的那一行演）
  var staged: (scene: PreviewScene, step: Int)? = nil
  /// 截图自检指定有没有刘海；nil = 看这台 Mac 的屏
  var notch: Bool? = nil
  @Environment(PreviewFocus.self) private var focus: PreviewFocus?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 设置窗关了（只是收起来）、退到后台时不演
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(Prefs.screenshotPlacement) private var placement = Prefs.ShotPlacement.corner.rawValue
  @AppStorage(Prefs.panelSqueezeEntrance) private var squeeze = false
  @AppStorage(Prefs.islandLevelAccent) private var levelAccent = false
  @AppStorage(Prefs.islandLevelPercent) private var levelPercent = false
  @AppStorage(Prefs.islandHoverDelay) private var hoverDelay = 0.3
  @AppStorage(Prefs.islandNotchClicks) private var notchClicks = true
  @AppStorage(Prefs.islandHoverExpands) private var hoverExpands = false
  /// 演到第几步（静止帧 = 这个场景的最后一步）
  @State private var step = 0
  /// 刘海岛场景每一轮新建一座摆出来的岛（它自己的计时会走，不复用）
  @State private var island: Island?

  static let height: CGFloat = 120

  /// 钉在页头下面、表单上面（刘海岛页和三个子页）：左右和分组表单的组对齐
  func pinned() -> some View { padding(.horizontal, 20).padding(.top, 10) }

  /// 正在演的那一行（减弱动态效果、截图自检、设置窗不在前台时不演）
  private var playing: PreviewScene? {
    staged == nil && !reduceMotion && appearsActive ? focus?.scene : nil
  }

  /// 演什么、照哪些设置演：任何一样变了就从头重演（跟着设置走，SPEC §6.1）
  private struct Play: Hashable {
    let scene: PreviewScene?
    let values: [String]
  }

  private var play: Play {
    Play(
      scene: playing,
      values: [
        placement, "\(squeeze)", "\(levelAccent)", "\(levelPercent)", "\(hoverDelay)",
        "\(notchClicks)", "\(hoverExpands)",
      ])
  }
  private var scene: PreviewScene { staged?.scene ?? playing ?? still }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    ZStack(alignment: .top) {
      LinearGradient(
        colors: AppearanceThumbnail.wallpaper(dark: colorScheme == .dark), startPoint: .top,
        endPoint: .bottom)
      // 菜单栏
      Color(white: colorScheme == .dark ? 0 : 1, opacity: 0.35).frame(height: 7)
      stage
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .clipShape(shape)
    .overlay(shape.hairlineBorder())
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    // 停着一行就一轮一轮地演；离开（playing 变成 nil）就取消、回到静止帧
    .task(id: play) { await run() }
    .task(id: staged.map { "\($0.scene)\($0.step)" }) { settle() }
  }

  // MARK: 每个场景画什么

  @ViewBuilder private var stage: some View {
    switch scene {
    case .placement: placementStage
    case .squeeze: squeezeStage
    default: islandStage
    }
  }

  /// 截完图放哪：选区闪一下，卡片飞到右下角 / 挂上晾衣绳 / 右下角白闪一下
  private var placementStage: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let center = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
      let choice = Prefs.ShotPlacement(rawValue: placement) ?? .corner
      let card = RoundedRectangle(cornerRadius: 3, style: .continuous)
      ZStack {
        if choice == .clothesline { clothesline(size) }
        // 选区：品牌粉 1 pt
        if step == 0 {
          Rectangle().strokeBorder(Style.brand, lineWidth: 1)
            .frame(width: 70, height: 44)
            .position(center)
        }
        switch choice {
        case .corner:
          shot(card)
            .frame(width: 66, height: 40)
            .scaleEffect(step == 0 ? 1 : 0.45)
            .position(step == 0 ? center : CGPoint(x: size.width - 26, y: size.height - 18))
        case .clothesline:
          // 落到绳上：缩成和挂着的那两张一样大，夹子跟着出现
          VStack(spacing: 0) {
            Capsule().fill(Style.brand).frame(width: 4, height: 6).opacity(step == 0 ? 0 : 1)
            shot(card).frame(width: step == 0 ? 66 : 26, height: step == 0 ? 40 : 16)
          }
          .position(
            step == 0
              ? CGPoint(x: center.x, y: center.y - 3) : CGPoint(x: size.width / 2 + 30, y: 32))
        case .none:
          if step == 0 { shot(card).frame(width: 66, height: 40).position(center) }
          Rectangle().fill(.white).frame(width: 46, height: 28)
            .position(x: size.width - 30, y: size.height - 20)
            .opacity(step == 1 ? 0.9 : 0)
        }
      }
    }
  }

  /// 一张截图卡片：一块渐变当截图，圆角、发丝线、阴影同角落的缩略图
  private func shot(_ shape: RoundedRectangle) -> some View {
    LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
      .clipShape(shape)
      .shotCard(shape)
  }

  /// 晾衣绳：菜单栏下面一根静止的悬链线、两张已经挂着的卡片和品牌粉夹子（不跑物理）
  private func clothesline(_ size: CGSize) -> some View {
    let card = RoundedRectangle(cornerRadius: 2, style: .continuous)
    return ZStack {
      Path { path in
        path.move(to: CGPoint(x: 12, y: 16))
        path.addQuadCurve(
          to: CGPoint(x: size.width - 12, y: 16), control: CGPoint(x: size.width / 2, y: 30))
      }
      .stroke(Color(white: colorScheme == .dark ? 0.85 : 0.35), lineWidth: 1)
      ForEach(0..<2, id: \.self) { index in
        let x = size.width / 2 - 70 + CGFloat(index) * 50
        VStack(spacing: 0) {
          Capsule().fill(Style.brand).frame(width: 4, height: 6)
          shot(card).frame(width: 26, height: 16)
        }
        .position(x: x, y: 32)
      }
    }
  }

  /// 挤压弹开：上方正中一块缩小的剪贴板面板，开着时从窄一点、矮一点弹到原尺寸（OverlayPanel.squeezeIn），关着时淡入 + 落下
  private var squeezeStage: some View {
    ClipboardPanelSketch(showsLens: true, showsLinkPreview: false)
      .scaleEffect(0.5, anchor: .top)
      .frame(height: Self.height - 14, alignment: .top)
      .scaleEffect(
        x: squeeze && step == 0 ? 0.9 : 1, y: squeeze && step == 0 ? 0.75 : 1, anchor: .top
      )
      .offset(y: !squeeze && step == 0 ? -6 : 0)
      .opacity(step == 0 ? 0 : 1)
      .padding(.top, 12)
  }

  /// 刘海岛：一座摆出来的岛放进 IslandView，缩到一半、只露刘海那一截
  @ViewBuilder private var islandStage: some View {
    if let island {
      // 缩放不改布局尺寸：外面那一层给缩完的宽，不然舞台按岛窗口的整宽排（撑出表单行）
      let size = island.geometry.windowSize
      IslandView(island: island)
        .frame(width: size.width, height: size.height)
        .scaleEffect(0.5, anchor: .top)
        .frame(width: size.width / 2, height: Self.height, alignment: .top)
    }
  }

  // MARK: 演

  /// 这个场景一共几步（最后一步 = 静止帧）：「点刘海打开」关着时点刘海没反应，「停在刘海上自动展开」关着时只鼓起一点
  private func last(_ scene: PreviewScene) -> Int {
    switch scene {
    case .placement: 1
    case .squeeze: 1
    case .notchClick: notchClicks ? 2 : 0
    case .hoverExpand: hoverExpands ? 2 : 1
    case .nowPlaying, .calendar, .levels: 1
    }
  }

  /// 不演时：摆好静止帧（或截图自检要的那一步）
  private func settle() {
    let scene = staged?.scene ?? still
    let target = staged?.step ?? last(scene)
    step = target
    island = Self.isIsland(scene) ? makeIsland(scene, step: target) : nil
  }

  /// 停着一行时一轮一轮地演（一轮 1.6–2.4 s，演完停 0.6 s 再来）；离开时被取消，回到静止帧
  private func run() async {
    guard let scene = playing, last(scene) > 0 else {
      settle()
      return
    }
    while !Task.isCancelled {
      step = 0
      island = Self.isIsland(scene) ? makeIsland(scene, step: 0) : nil
      try? await Task.sleep(for: .milliseconds(400))
      for next in 1...last(scene) {
        guard !Task.isCancelled else { return }
        withAnimation(animation(scene, step: next)) { advance(scene, to: next) }
        try? await Task.sleep(for: .milliseconds(delay(scene, after: next)))
      }
      // 被取消的那一轮别再动 step（不然可能盖掉新任务摆好的静止帧）
      if scene == .squeeze, !Task.isCancelled {
        withAnimation(.easeIn(duration: 0.15)) { step = 0 }
      }
      try? await Task.sleep(for: .milliseconds(600))
    }
  }

  /// 每一步用哪条曲线（同真的：飞行卡片落地、刘海岛长出来是 island；挤压弹开照 OverlayPanel.squeezeIn）
  private func animation(_ scene: PreviewScene, step: Int) -> Animation? {
    switch scene {
    case .placement:
      (Prefs.ShotPlacement(rawValue: placement) ?? .corner) == .none
        ? .easeOut(duration: 0.12) : Style.Motion.island.animation(reduced: false)
    case .squeeze: squeeze ? .spring(duration: 0.42, bounce: 0.22) : .easeOut(duration: 0.2)
    default: Style.Motion.island.animation(reduced: false)
    }
  }

  /// 走完这一步停多久（毫秒）
  private func delay(_ scene: PreviewScene, after step: Int) -> Int {
    switch (scene, step) {
    case (.hoverExpand, 1): Int(hoverDelay * 1000) + 300
    case (.notchClick, 1): 600
    default: 1600
    }
  }

  private func advance(_ scene: PreviewScene, to next: Int) {
    step = next
    guard let island else { return }
    Self.apply(scene, step: next, to: island)
  }

  // MARK: 刘海岛

  private static func isIsland(_ scene: PreviewScene) -> Bool {
    switch scene {
    case .placement, .squeeze: false
    default: true
    }
  }

  /// 照真的岛：这台 Mac 有刘海的屏就演那块屏的刘海形体，没有就演浮着的胶囊（截图自检用 notch 指定）
  private var geometry: Island.Geometry {
    if let notch { return notch ? .notch(width: 200, height: 32) : .capsule(menuBar: 24) }
    return Island.notchScreen.map(Island.geometry(of:)) ?? .capsule(menuBar: 24)
  }

  /// 新建一座摆出来的岛，摆到这一步
  private func makeIsland(_ scene: PreviewScene, step: Int) -> Island {
    let island: Island
    switch scene {
    case .notchClick:
      island = Island(
        showing: nil, geometry: geometry, board: Self.records,
        quickActions: HotKeyAction.islandShortcuts.prefix(5).map {
          Island.Action($0.titleResource, symbol: $0.symbol) {}
        })
      island.isOpen = false
      island.isBoardOpen = false
    case .hoverExpand:
      island = Island(showing: nil, geometry: geometry, activities: [Self.awake])
    default:
      island = Island(showing: nil, geometry: geometry)
      island.levelAccent = levelAccent
      island.levelPercent = levelPercent
    }
    for done in stride(from: 1, through: step, by: 1) { Self.apply(scene, step: done, to: island) }
    return island
  }

  /// 一步：鼓起、打开那一张、展开卡片、挂上活动、亮出音量那一行
  private static func apply(_ scene: PreviewScene, step: Int, to island: Island) {
    switch (scene, step) {
    case (.notchClick, 1), (.hoverExpand, 1): island.isPeeking = true
    case (.notchClick, 2):
      island.isPeeking = false
      island.isOpen = true
      island.isBoardOpen = true
    case (.hoverExpand, 2):
      island.isPeeking = false
      // 同真的停留展开（expandActivity，不是点一下的 tapped）
      if case .notch = island.geometry { island.expandActivity() } else { show(awake, on: island) }
    case (.nowPlaying, 1): show(media, on: island)
    case (.calendar, 1): show(event, on: island)
    // 停得够久：子页里它是静止帧，按岛的停留两秒就收了（演的时候每一轮新建一座岛，照样两秒左右换下一轮）
    case (.levels, 1):
      island.showLevel(Island.Level(kind: .volume, fraction: 0.625, stay: .seconds(3600)))
    default: break
    }
  }

  /// 挂上一个活动：有刘海时挂在两边的耳朵上；没刘海的屏上活动在菜单栏里，舞台上演成岛上展开的一条
  private static func show(_ activity: Island.Activity, on island: Island) {
    if case .notch = island.geometry {
      island.activities = [activity]
      island.isShowingWings = true
    } else {
      // 直接摆成它的卡片（不走 expand：那会排停留计时）；胶囊上不会因此冒出耳朵
      island.activities = [activity]
      island.expandedActivity = activity.id
      island.actions = activity.actions
      island.content = activity.content
      island.isOpen = true
      island.isExpanded = true
    }
  }

  /// 那一张上列的两条提示（摆的，不是这台 Mac 的）
  private static var records: [Island.Record] {
    [
      Island.Record(
        content: .init(
          title: "已复制", detail: "https://example.com", tone: .success,
          symbol: "checkmark.circle.fill", leading: .tone), actions: [],
        at: .now.addingTimeInterval(-60)),
      Island.Record(
        content: .init(
          title: "已存储", detail: "截图.png", tone: .success,
          symbol: "checkmark.circle.fill",
          leading: .color(.systemTeal)), actions: [], at: .now.addingTimeInterval(-600)),
    ]
  }

  /// 挂在刘海两边的活动：保持唤醒（自动展开演它的卡片）、正在播放（封面是一块渐变，不读用户的东西）、十分钟内的日程
  private static var awake: Island.Activity {
    KeepAwake.activity(until: .now.addingTimeInterval(3600), display: true) {}
  }

  private static var media: Island.Activity {
    let cover = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
      NSGradient(colors: [.systemPink, .systemOrange])?.draw(in: rect, angle: 45)
      return true
    }
    let snapshot = NowPlayingSnapshot(
      bundleID: "com.apple.Music", parentBundleID: nil, appName: "", title: "Kitty",
      artist: "Kitty Tools",
      album: "", duration: 240, elapsed: 84, timestamp: .now, rate: 1, isPlaying: true,
      canPrevious: true, canNext: true, canSeek: true, shuffle: nil, repeatMode: nil,
      artworkID: "preview", artwork: nil)
    return Island.Activity(
      id: NowPlaying.activityID, kind: .media, title: snapshot.title, detail: snapshot.artist,
      symbol: "music.note",
      media: Island.Media(
        snapshot: snapshot, artwork: cover, tint: ArtworkTint.color(of: cover), appIcon: nil,
        send: { _ in }, seek: { _ in }, open: {}))
  }

  private static var event: Island.Activity {
    Island.Activity(
      id: "settings-preview-event", kind: .event, title: String(localized: "周会"),
      symbol: "calendar",
      trailing: .countdown(to: .now.addingTimeInterval(8 * 60)))
  }
}
