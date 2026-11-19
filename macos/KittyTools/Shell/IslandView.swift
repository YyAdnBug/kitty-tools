// 刘海岛的画面（第五轮体检 H1 从 Island.swift 拆出）：IslandView 和它用的几件——前导位、按钮、卡片排版、出场 / 退场的修饰、形体的几何和轮廓。

import AppKit
import SwiftUI

/// 岛的画面：一块定死的透明画布上，黑色形体（刘海屏带耳朵的下巴 / 其它屏的胶囊）+ 内容（一行、卡片或那一张）。
/// **动画只有一份几何**（宽、高、耳朵、底角）：形体、裁内容的遮罩、阴影都读它，弹簧只推这几个数；内容按最终尺寸一次排好、
/// 被同一个形体裁出来，每帧只是路径在变，形体和内容天然同步（2026-10-26 用户报卡顿，照开源刘海项目改：jackson-storm/
/// DynamicNotch 的遮罩、CodeIsland 的最小尺寸和开 / 关两条弹簧、boring.notch 的收起不过冲，调研在
/// build/research/notch-oss-shell.md §5.3）
struct IslandView: View {
  let island: Island
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 内容排好的大小：只记正在出场 / 显示着的那一份（换内容时退场的旧内容不算，免得形体先撑到两者的并集再缩回）；
  /// 收起后留着最后一份，形体照它缩回
  @State private var contentSize = CGSize.zero
  /// 收着时那一行多宽：卡片至少这么宽——卡片盖得住那一行，指针不会因为展开被挤到外面（进行中的会来回开合），
  /// 主按钮展开前后也差不多在同一处
  @State private var rowWidth: CGFloat = 0

  var body: some View {
    let geometry = island.geometry
    let shape = shape(geometry)
    ZStack(alignment: .top) {
      backdrop(shape)
      ZStack(alignment: .top) {
        content.padding(.top, shape.contentTop)
        // 刘海两边的东西贴着形体的边走：形体这一刻多宽，跟着形体的那条曲线逐帧报给它们（EdgeRide）
        Group {
          wings(geometry)
          levelWings(geometry)
        }
        .modifier(
          EdgeRide(
            width: shape.frame.width, notch: geometry.notchWidth, levelWing: island.levelWing)
        )
        // 减弱动态效果时不挂这条（形体本来就不伸缩；curve 是 nil，挂上会把这棵子树里同一拍的动画清掉）
        .animation(curve, value: reduceMotion ? 0 : shape.frame.width)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .mask { IslandOutline(shape: shape).animation(curve, value: shape) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .contentShape(IslandOutline(shape: shape))
    .onTapGesture { island.tapped() }
    .onChange(of: shape.frame, initial: true) { island.shapeFrame = shape.frame }
    .onChange(of: island.wantsBackdrop) { island.syncBackdrop() }
    .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
    .modifier(Press(count: island.presses, enabled: !reduceMotion))
    .modifier(Presence(island: island, capsule: shape.capsule, reduceMotion: reduceMotion))
    .environment(\.colorScheme, .dark)
  }

  /// 这一刻形体该长成什么样（目标值，不是动画中途的值）：刘海屏开着时 = 内容 + 刘海，最小刘海宽 + 64、下巴 36；
  /// 指针停在刘海上鼓起一圈；收起缩进真刘海里面（IslandGeometry.tucked）。无刘海屏一直是内容那么大（收起靠缩放 + 淡出）
  private func shape(_ geometry: Island.Geometry) -> IslandGeometry {
    let canvas = Island.canvasWidth
    switch geometry {
    case .notch(let notchWidth, let notchHeight):
      // 减弱动态效果：形体不伸缩（一直是开着的大小），整座岛只淡入淡出；鼓起、耳朵照常
      let wings = island.isShowingWings && !island.isOpen
      let open = island.isOpen || (reduceMotion && !island.isPeeking && !wings)
      let peek = island.isPeeking && !island.isOpen
      let large = island.isExpanded || island.isBoardOpen || island.cardActivity != nil
      // 捏回刘海（换内容的中间那一下）：每侧只多 4；音量 / 亮度的提示：只在刘海两边各伸出一截、和刘海一样高
      // （IslandLevelWings）；坐在刘海里（Island.seated）：收着那么窄、刘海那么高
      if island.pinched || island.levelShaped || island.isSeated {
        let tucked = IslandGeometry.tucked(notchWidth: notchWidth, notchHeight: notchHeight)
        let shown = island.pinched || island.levelShaped
        let width =
          island.pinched
          ? notchWidth + 8 : (island.levelShaped ? notchWidth + island.levelWing * 2 : tucked.width)
        let height = notchHeight + (island.levelShaped ? Island.levelDrop : 0)
        return IslandGeometry(
          frame: CGRect(x: (canvas - width) / 2, y: 0, width: width, height: height),
          ear: shown ? 10 : 0, bottom: shown ? 12 : 8, floor: tucked, contentTop: notchHeight,
          capsule: false)
      }
      let size =
        if open {
          // 一瞥：和耳朵一样宽（耳朵还露着，只是往下垂了一行）
          CGSize(
            width: max(notchWidth + (island.isGlance ? Island.wing * 2 : 64), contentSize.width),
            height: notchHeight + max(Island.chin, contentSize.height))
        } else if wings {
          // 耳朵：刘海两侧各 36，和刘海同高；指针停上去同样鼓起一圈
          CGSize(
            width: notchWidth + Island.wing * 2 + (peek ? Island.peekGrow.width * 2 : 0)
              + abs(island.stretch),
            height: notchHeight + (peek ? Island.peekGrow.height : 0))
        } else if peek {
          CGSize(
            width: notchWidth + Island.peekGrow.width * 2,
            height: notchHeight + Island.peekGrow.height)
        } else {
          IslandGeometry.tucked(notchWidth: notchWidth, notchHeight: notchHeight)
        }
      var geometry = IslandGeometry(
        frame: CGRect(x: (canvas - size.width) / 2, y: 0, width: size.width, height: size.height),
        // 圆角照 Alcove 的实录量的（2026-11-14；同一种量法它的卡片底角约 32、顶上的弧高 15 往外 18，我们原来 15 / 6）：
        // 大面（卡片、那一张）底角 44、顶上两侧的弧 24；一行的提示 24 / 12；耳朵、鼓起 10
        ear: open ? (large ? Island.largeEar : 12) : (peek || wings ? 10 : 0),
        bottom: open ? (large ? Island.largeCorner : 24) : (peek ? 13 : (wings ? 12 : 8)),
        floor: IslandGeometry.tucked(notchWidth: notchWidth, notchHeight: notchHeight),
        contentTop: notchHeight, capsule: false)
      // 滑动切歌：只往一侧伸（另一侧的边不动）——整体宽了 stretch、中线往那一侧挪一半
      if wings, !open { geometry.shift = island.stretch / 2 }
      return geometry
    case .capsule:
      let size = CGSize(
        width: min(max(120, contentSize.width), Island.maxWidth),
        height: max(Island.chin, contentSize.height))
      return IslandGeometry(
        frame: CGRect(x: (canvas - size.width) / 2, y: 2, width: size.width, height: size.height),
        ear: 0, bottom: Island.chin / 2, floor: .zero, contentTop: 2, capsule: true)
    }
  }

  /// 形体的弹簧：开着（出现、展开、换内容、开那一张）带一点弹；收起不过冲（终点藏在刘海里，过冲会露出来）；
  /// 鼓起是 pop（小东西出现的那条，带一点弹）。减弱动态效果时不伸缩
  private var curve: Animation? {
    if reduceMotion { return nil }
    // 捏回刘海 0.24 s、音量 / 亮度的提示长开 0.4 s，都不过冲（照 Alcove 的实录）
    if island.pinched { return .smooth(duration: 0.24) }
    if island.levelShaped { return .smooth(duration: 0.4) }
    // 音量 / 亮度的提示收回空刘海：比别的收起慢一点、尾巴长（Alcove：约 0.09 s 走一半、0.27 s 走九成）
    if island.isSeated { return .smooth(duration: 0.42) }
    if island.isOpen {
      // 大面（卡片、那一张）冲过头一点再落回；一行的提示、一瞥不过冲那么多
      return island.isExpanded || island.isBoardOpen
        ? Island.bloom : Style.Motion.island.animation()
    }
    return island.isPeeking ? Style.Motion.pop.animation() : Style.Motion.retract.animation()
  }

  /// 黑底：刘海屏纯黑带耳朵，无刘海屏 black 0.92 + 发丝线的圆角卡片；只有开着时有阴影（挂在纯形体上，不挂在内容上）
  /// 不按两种屏分支（分支一换就是新视图，动画没有起点）：两种屏只是颜色、描边的参数不同
  private func backdrop(_ shape: IslandGeometry) -> some View {
    let outline = IslandOutline(shape: shape)
    return outline.fill(.black.opacity(shape.capsule ? 0.92 : 1))
      .overlay(
        outline.hairlineBorder(.white.opacity(shape.capsule ? 0.12 : island.outlined ? 0.22 : 0))
      )
      // 音量 / 亮度的提示贴在刘海那一行里，不算展开：没有阴影。
      // ponytail: 没有刘海的屏上有模糊时不画阴影（同第 12 批）——形体离窗口上沿只有 2 pt，又宽又淡的那一圈会在
      // 卡片上方被窗口切成一道平顶；要补就把那块屏上的窗口往上加高（place 的 top、shape 里胶囊的 y 一起改）
      .islandShadow(
        open: island.isOpen && (shape.capsule ? !island.blursNow : !island.levelShaped),
        soft: island.blursNow
      )
      .animation(curve, value: shape)
  }

  /// 收着是一行（前导 + 标题 + 详情 + 主按钮），展开是卡片；那一张开着时是 IslandBoard。换内容时模糊交叉替换，
  /// 新的晚 60 ms 出场
  @ViewBuilder private var content: some View {
    ZStack(alignment: .top) {
      if island.isBoardOpen {
        IslandBoard(island: island)
          .measured { report($0) }
          .transition(appear)
      } else if island.isShowingLevel, let level = island.level {
        // 音量 / 亮度：没有刘海的屏上是一行（换数不重新出场）；刘海屏上画在刘海两边（levelWings），这里不占地方
        if case .capsule = island.geometry {
          IslandLevelRow(level: level, accent: island.levelAccent, bumps: island.levelBumps)
            .measured { report($0) }
            .transition(appear)
        }
      } else if island.content != nil, let media = island.cardActivity?.media {
        // 点耳朵展开的正在播放：播放卡片（IslandMedia.swift）；换歌、暂停原地换，不重新出场
        IslandMediaCard(island: island, media: media)
          .measured { report($0) }
          .transition(appear)
      } else if island.isGlance, !island.isExpanded, let content = island.content,
        case .notch(let width, _) = island.geometry
      {
        // 一瞥（换歌）：耳朵上的封面和波形不动（wings），下面只垂一行「♪ 歌名 · 艺人」，和耳朵一样宽、放不下截断
        // （2026-11-14 照 Alcove 的实录：原来整条换成带缩略图的一行，耳朵跟着没了）
        glanceRow(content, width: width + Island.wing * 2)
          .measured { report($0) }
          .id(content.title + (content.detail ?? ""))
          .transition(appear)
      } else if let content = island.content {
        Group {
          if content.isPinned {
            // 收着、展开是同一个视图（不交叉淡入淡出）：第一行一直不动，展开只往下长
            pinnedCard(content).measured { report($0) }
          } else if island.isExpanded {
            card(content).measured { report($0) }.transition(.opacity)
          } else {
            row(content).measured { report($0) }.transition(.opacity)
          }
        }
        // 进行中的岛只按标题认：详情里的百分比一直在变，不能每变一次就整行重新出场
        .id(content.tone == .progress ? content.title : content.title + (content.detail ?? ""))
        .transition(appear)
      }
    }
  }

  /// 耳朵上的两小块（收起、有活动时）：画在刘海那一行里，不垫刘海高度；出现、换了露的活动都是模糊着进出（melt）
  @ViewBuilder private func wings(_ geometry: Island.Geometry) -> some View {
    // 一瞥出着时耳朵照旧露着（它只是往下垂了一行）。岛上的东西已经在退、形体还没开始缩的那两帧（dismiss 的
    // retractLag：content 空了、isOpen 还是 true）也算——不然一瞥收回时耳朵会被拆掉再重建、闪一下（评审 1）；
    // 别的提示收起时耳朵早两帧开始进来
    // 捏回刘海时（island.pinched）不拆：原地淡掉、跟着边往回走（见 EdgeRide）
    if case .notch(let width, let height) = geometry, island.isShowingWings,
      !island.isOpen || island.isGlance || (island.content == nil && !island.isBoardOpen),
      let activity = island.activity
    {
      ZStack {
        IslandWings(
          activity: activity, notchWidth: width, notchHeight: height, peeking: island.isPeeking,
          skip: island.skip, focusMark: island.focusMark
        )
        .id(activity.id)
        .transition(melt)
        // 滑动切歌：伸出去的那一截里的箭头（形体的那一截由 shape() 伸出来）
        if island.stretch != 0 {
          let side: CGFloat = island.stretch > 0 ? 1 : -1
          Image(systemName: island.stretch > 0 ? "forward.fill" : "backward.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: height)
            .offset(
              x: side
                * (width / 2 + Island.wing + (island.isPeeking ? Island.peekGrow.width : 0)
                  + Island.stretchReach / 2 - 3)
            )
            .transition(melt)
            .accessibilityHidden(true)
        }
      }
      .modifier(Melt(progress: island.pinched ? 0 : 1, scales: false))
      .animation(.smooth(duration: 0.24), value: island.pinched)
      .allowsHitTesting(!island.pinched)
      .transition(melt)
    }
  }

  /// 音量 / 亮度的提示（刘海屏）：画在刘海那一行里、刘海两边；换数不重新出场
  @ViewBuilder private func levelWings(_ geometry: Island.Geometry) -> some View {
    // 捏回刘海时、刚收起的那 0.3 秒（departingLevel）不拆：原地淡掉、跟着边往回走（同耳朵）
    if case .notch(let width, let height) = geometry,
      let level = island.isShowingLevel ? island.level : island.departingLevel
    {
      let fading = island.pinched || !island.isShowingLevel
      IslandLevelWings(
        level: level, notchWidth: width, notchHeight: height + Island.levelDrop,
        accent: island.levelAccent, percent: island.levelPercent, bumps: island.levelBumps
      )
      .modifier(Melt(progress: fading ? 0 : 1, scales: false))
      .animation(.smooth(duration: 0.24), value: fading)
      // 换了种类（音量 → 亮度）是另一个：旧的糊着退、新的糊着进（进来的慢半拍：形体长到一半才看得清，同 Alcove）
      .id(level.identity)
      .transition(
        reduceMotion
          ? melt
          : .asymmetric(
            insertion: .modifier(active: Melt(progress: 0), identity: Melt(progress: 1))
              .animation(.smooth(duration: 0.3).delay(0.08)),
            removal: melt))
    }
  }

  /// 内容量好的大小：岛上有东西时才记（收起后退场的那一份不覆盖，形体照最后一份缩回）
  private func report(_ size: CGSize) {
    guard island.content != nil || island.isBoardOpen, size.width > 0 else { return }
    contentSize = size
  }

  /// 内容出场：晚 60 ms，blur 8 → 0、scale 0.9 → 1（顶部锚点）、透明度（smooth 0.28）；退场同一套反着走、0.18 s
  /// （2026-11-14 照 Alcove：内容进出一律「模糊 + 缩放」，原来退场是 0.12 s 纯淡出）。形体那边同时在长 / 缩，内容被它裁着
  private var appear: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .modifier(
          active: Emerge(progress: 0), identity: Emerge(progress: 1)
        ).animation(.smooth(duration: 0.28).delay(0.06)),
        removal: .modifier(
          active: Emerge(progress: 0), identity: Emerge(progress: 1)
        ).animation(.easeIn(duration: 0.18)))
  }

  /// 刘海那一行里的小东西（耳朵上的封面、读数、音量提示）进出：blur 6 → 0、scale 0.85 → 1（原地）、透明度，0.24 s；
  /// 减弱动态效果时只淡
  private var melt: AnyTransition {
    reduceMotion
      ? .opacity.animation(.easeInOut(duration: 0.2))
      : .modifier(active: Melt(progress: 0), identity: Melt(progress: 1))
        .animation(.smooth(duration: 0.24))
  }

  /// 一瞥的那一行：音符 + 歌名 + 「· 艺人」，居中，12 pt；和耳朵那一条一样宽
  private func glanceRow(_ content: Island.Content, width: CGFloat) -> some View {
    HStack(spacing: 5) {
      Image(symbol: content.symbol)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
      Text(content.title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
        .layoutPriority(1)
      if let detail = content.detail {
        Text("· \(detail)")
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.55))
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .padding(.horizontal, 14)
    .frame(width: width, height: Island.chin - 4)
    .accessibilityElement(children: .combine)
  }

  private func row(_ content: Island.Content) -> some View {
    let room = Island.rowRoom(
      title: content.title, detail: content.detail, buttons: island.actions.prefix(1).map(\.title),
      fraction: content.fraction != nil)
    return HStack(spacing: 10) {
      IslandLeading(content: content)
      // 放得下时不套 frame：排法和原来一模一样
      if let cap = room.title {
        title(content).frame(maxWidth: cap, alignment: .leading)
      } else {
        title(content)
      }
      if let activity = island.cardActivity { IslandActivityReading(activity: activity) }
      fractionBar(content)
      if let detail = content.detail { inlineDetail(detail, content, width: room.detail) }
      if let first = island.actions.first {
        IslandButton(title: first.title, prominent: false, selected: island.buttonSelection == 0) {
          island.perform(first)
        }
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
        IslandLeading(content: content)
        title(content)
        if let activity = island.cardActivity { IslandActivityReading(activity: activity) }
        fractionBar(content)
        Spacer(minLength: 12)
        HStack(spacing: 8) {
          actionButtons
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
      if let detail = content.detail { foldedDetail(detail, content) }
    }
    .padding(.horizontal, 18)
  }

  /// 挂着直到处理的那条（提醒，Island.pin）：收着和展开是同一个视图。按钮一开始就全露着（主按钮白底在最右，同卡片），
  /// 展开只往下长出完整详情——第一行不重排（行内的详情原地淡掉、位置空着）、宽度只按第一行定，指针移上去前后按钮、
  /// 标题在屏上一点不挪（2026-11-18 用户反馈：原来悬停才冒出来的「稍后」挤进「知道了」原来的位置、× 又插在它右边，
  /// 好几次点错）。没有 ×：它就是主按钮「知道了」，双指上滑照旧
  private func pinnedCard(_ content: Island.Content) -> some View {
    let expanded = island.isExpanded
    let room = Island.rowRoom(
      title: content.title, detail: content.detail, buttons: island.actions.map(\.title),
      fraction: false)
    return CardLayout(minWidth: 0, maxWidth: Island.maxWidth - 36, firstRowOnly: true) {
      HStack(spacing: 10) {
        IslandLeading(content: content)
        title(content).frame(maxWidth: room.title, alignment: .leading)
        if let detail = content.detail {
          inlineDetail(detail, content, width: room.detail)
            .opacity(expanded ? 0 : 1)
            .accessibilityHidden(expanded)
        }
        HStack(spacing: 8) { actionButtons }
      }
      .frame(height: Island.chin)
      if expanded, let detail = content.detail { foldedDetail(detail, content) }
    }
    .padding(.horizontal, 18)
  }

  /// 这一条的按钮，主按钮（第一个，白底黑字）在最右
  private var actionButtons: some View {
    ForEach(Array(island.actions.enumerated().reversed()), id: \.offset) { index, action in
      IslandButton(
        title: action.title, prominent: index == 0, selected: island.buttonSelection == index
      ) { island.perform(action) }
    }
  }

  /// 收着那一行里的详情：一行、中间截断
  private func inlineDetail(_ detail: String, _ content: Island.Content, width: CGFloat)
    -> some View
  {
    Text(detail)
      .font(detailFont(content))
      .foregroundStyle(.white.opacity(0.55))
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(maxWidth: width, alignment: .leading)
  }

  /// 卡片里折在第一行下面的完整详情：最多 4 行，和标题左对齐
  private func foldedDetail(_ detail: String, _ content: Island.Content) -> some View {
    Text(detail)
      .font(detailFont(content))
      .foregroundStyle(.white.opacity(0.55))
      .lineLimit(4)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.leading, 32)
      .padding(.bottom, 12)
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
          Rectangle().fill(IslandLeading.tint(content.tone))
            .frame(width: 56 * min(max(fraction, 0), 1))
        }
        .clipShape(Capsule())
        .frame(width: 56, height: 4)
        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
        .accessibilityHidden(true)
    }
  }

}

/// 前导位置（22 × 22）：语气色圆底的符号、取色的色块或截图的缩略图。提示和那一张里的列表共用
struct IslandLeading: View {
  let content: Island.Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
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
      let ink =
        content.tint.map(Self.ink(on:))
        ?? (content.tone == .info || content.tone == .progress ? Style.onBrand : .white)
      let plate = content.tint.map { Color(nsColor: $0) } ?? Self.tint(content.tone)
      Group {
        if Island.hasPlate(content.symbol) {
          Image(symbol: content.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(ink, plate)
        } else {
          // 没有圆底变体的符号：垫一个语气色圆。圆是同字号的 circle.fill，和 xxx.circle.fill 的圆一样大（约 18.5 pt）；
          // 符号放进 12 × 12（和系统圆底符号里的那个差不多大），宽的（键盘、带角标的文件夹）跟着缩，不出圆
          Image(systemName: "circle.fill")
            .foregroundStyle(plate)
            .overlay {
              Image(symbol: content.symbol)
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

  /// 自己颜色的圆底（专注模式、日历的颜色）上的符号：亮的底（黄、薄荷绿……）用深色，别的用白（评审：黄底白字看不清）
  static func ink(on color: NSColor) -> Color {
    guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
    let luminance =
      0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance > 0.6 ? .black.opacity(0.85) : .white
  }

  static func tint(_ tone: Island.Tone) -> Color {
    switch tone {
    case .success: Color(nsColor: .systemGreen)
    case .info, .progress: Style.brand
    case .warning: Color(nsColor: .systemOrange)
    case .error: Color(nsColor: .systemRed)
    }
  }
}

/// 点到了岛本身：整座岛缩到 0.96 再弹回（顶边不动，同岛上按钮按下的手感），count 变一次播一次
private struct Press: ViewModifier {
  let count: Int
  let enabled: Bool

  func body(content: Content) -> some View {
    content.keyframeAnimator(initialValue: CGFloat(1), trigger: count) { view, scale in
      view.scaleEffect(enabled ? scale : 1, anchor: .top)
    } keyframes: { _ in
      KeyframeTrack {
        CubicKeyframe(0.96, duration: 0.08)
        SpringKeyframe(1, duration: 0.26, spring: .snappy)
      }
    }
  }
}

/// 岛在不在：无刘海屏收起时缩到 0.6、淡掉（顶部锚点）；刘海屏减弱动态效果时只淡入淡出。都是渲染变换，不重排；
/// 不按两种屏分支（理由同 backdrop）
private struct Presence: ViewModifier {
  let island: Island
  let capsule: Bool
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    let open = island.isOpen
    let shown =
      capsule ? open : !(reduceMotion && !open && !island.isPeeking && !island.isShowingWings)
    return
      content
      .scaleEffect(capsule && !open && !reduceMotion ? 0.6 : 1, anchor: .top)
      .opacity(shown ? 1 : 0)
  }
}

extension View {
  /// 量这块内容排好的大小（出现时、变了时各报一次；动画中途不报：内容自己不做尺寸动画）
  fileprivate func measured(_ report: @escaping (CGSize) -> Void) -> some View {
    onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      report($0)
    }
  }
}

/// 岛上的胶囊按钮：12 semibold、高约 22；主按钮（展开后最右那个）白底黑字，其余 white 0.16 底白字。
/// selected：键盘交给了这几个按钮、选中的是它（快捷键「打开刘海岛」，第五轮体检 A2）——外面隔 3 pt 一圈 2 pt 强调色焦点环，
/// 同那一张上选中的快捷动作
struct IslandButton: View {
  let title: String
  let prominent: Bool
  var selected = false
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
        // 屏外截图自检里这一圈两头各多一小段竖线，真机没有（来历见 Style.swift 的 hudSkin）
        .overlay {
          if selected {
            Capsule(style: .continuous).strokeBorder(Style.brand, lineWidth: 2).padding(-3)
          }
        }
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// 按下缩到 0.96、淡一点（不当 key 的窗口里 SwiftUI 的悬停不可靠，不做悬停底）
struct IslandButtonStyle: ButtonStyle {
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
  /// 只按第一行定宽、详情在这个宽度里折行（挂着的那条：展开前后一样宽，按钮不挪）
  var firstRowOnly = false

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
    let rows = firstRowOnly ? subviews.prefix(1) : subviews
    let widest = rows.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    return min(max(widest.rounded(.up), minWidth), maxWidth)
  }
}

extension View {
  /// 展开态的阴影（mac-whisker §3「层级」：black 0.45 / 模糊 14 / 向下 6）：刘海下巴和无刘海的胶囊同一组
  /// soft：四周有渐进模糊时换成又宽又淡的一圈压暗（2026-11-14 量 Alcove：6 pt 处暗 20%、16 pt 处 13%、26 pt 处
  /// 8%、36 pt 处 5%、46 pt 处 3%；这组参数屏上量到 12 / 8 / 5 / 3）。原来那道又窄又重的压在模糊上，背后的字像被
  /// 抹掉了；整个不要又浮不起来
  fileprivate func islandShadow(open: Bool, soft: Bool = false) -> some View {
    shadow(
      color: .black.opacity(open ? (soft ? 0.6 : 0.45) : 0), radius: soft ? 32 : 14,
      y: soft ? 2 : 6)
  }
}

/// 把形体这一刻的宽度（动画中途的值）折成「刘海两边的东西要往中间挪多少」报下去（Island.ride）：形体的宽度变了，
/// 它跟着同一条曲线逐帧重算——耳朵、音量 / 亮度的提示就贴着边一起走。形体比它们宽时两个数都是 0、不变，不会每帧
/// 重画（展开成卡片的那几百毫秒里什么都不做）。没有刘海的屏上不用。
/// 两条屏上录出来的教训：① 要用普通的 `.modifier(…).animation(curve, value:)`——写成
/// `.animation(curve) { $0.modifier(EdgeRide(…)) }` 时环境里的数根本传不下去（两个数一直是 0）；② 形体捏回刘海时
/// 耳朵、音量提示都不拆，原地淡掉（wings / levelWings 里的 Melt(scales: false)）——这样跟边走不靠「退场中的视图还
/// 收不收得到更新」
/// nonisolated：动画的中间值是系统插的，不保证在主线程上设（mac-native §3，同 IslandOutline）；body 照旧在主线程
nonisolated private struct EdgeRide: ViewModifier, Animatable {
  var width: CGFloat
  /// 刘海宽；没有刘海的屏是 nil
  let notch: CGFloat?
  /// 音量 / 亮度那种提示每侧伸出多宽（专注模式的随名字长短，Island.levelWing）
  let levelWing: CGFloat

  var animatableData: CGFloat {
    get { width }
    set { width = newValue }
  }

  @MainActor func body(content: Content) -> some View {
    if let notch {
      content
        .environment(
          \.islandWingRide, Island.ride(wing: Island.wing, notch: notch, shape: width)
        )
        .environment(
          \.islandLevelRide, Island.ride(wing: levelWing, notch: notch, shape: width))
    } else {
      content
    }
  }
}

/// 刘海那一行里的小东西进出：blur 6 → 0、scale 0.85 → 1（原地）、透明度。scales false：不缩放（捏回刘海时原地淡掉
/// 的耳朵、音量提示：它们自己跟着边走，整条再朝中间缩就离边越来越远）
private struct Melt: ViewModifier {
  let progress: Double
  var scales = true

  func body(content: Content) -> some View {
    content
      .blur(radius: 6 * (1 - progress))
      .scaleEffect(scales ? 0.85 + 0.15 * progress : 1)
      .opacity(progress)
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

/// 形体的一份几何：画布里的位置大小、耳朵、底角（动画只推这几个数），和不参与动画的最小尺寸（真刘海：弹簧过冲也露不出来）
nonisolated struct IslandGeometry: Equatable {
  var frame: CGRect
  var ear: CGFloat
  var bottom: CGFloat
  var floor: CGSize
  /// 内容从多高开始排（刘海屏在刘海下面，无刘海屏离画布顶 2）
  var contentTop: CGFloat
  /// 无刘海屏的圆角卡片（没有耳朵、四角同一个半径）
  var capsule: Bool
  /// 形体的中线往右挪多少（滑动切歌时往一侧伸；平时 0）。可动画
  var shift: CGFloat = 0

  /// 刘海屏收起时的形体：缩进真刘海里面（每侧让出 6、底边让出 6、没有耳朵、底角 8），被硬件刘海整个挡住。
  /// 收起的终点要是比刘海大（原来每侧宽 2、顶上带 6 的耳朵），缩回走完移走窗口时露在外面的那几点黑边一下子没了，
  /// 看着像最后卡了一下（2026-10-26 用户录屏：提示收起、悬停刘海后退出都这样）；出现时也从刘海里面长出来。
  /// notchWidth 是 Island.geometry 给的宽（真刘海 + 4）
  static func tucked(notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
    CGSize(width: max(notchWidth - 16, 0), height: max(notchHeight - 6, 0))
  }
}

/// 刘海岛形体：刘海屏是顶边两侧向外弯出的「耳朵」（凹弧接到菜单栏顶边）+ 圆角下巴；无刘海屏是圆角 = 半高（最大 18）的
/// 连续圆角矩形，一行时就是胶囊，展开成卡片后圆角 18，同一种形状能连续变。宽高、耳朵、底角可动画；路径按画布居中
/// nonisolated：path(in:) 可能在 SwiftUI 的异步渲染线程上调，纯几何计算，不绑定主线程
nonisolated struct IslandOutline: InsettableShape {
  var shape: IslandGeometry
  var inset: CGFloat = 0

  var animatableData:
    AnimatablePair<
      AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>, CGFloat
    >
  {
    get {
      AnimatablePair(
        AnimatablePair(
          AnimatablePair(shape.frame.width, shape.frame.height),
          AnimatablePair(shape.ear, shape.bottom)),
        shape.shift)
    }
    set {
      let size = newValue.first.first
      shape.frame.origin.x += (shape.frame.width - size.first) / 2
      shape.frame.size = CGSize(width: size.first, height: size.second)
      shape.ear = newValue.first.second.first
      shape.bottom = newValue.first.second.second
      shape.shift = newValue.second
    }
  }

  func inset(by amount: CGFloat) -> IslandOutline {
    var copy = self
    copy.inset += amount
    return copy
  }

  func path(in canvas: CGRect) -> Path {
    let width = max(shape.frame.width, shape.floor.width)
    let height = max(shape.frame.height, shape.floor.height)
    let rect = CGRect(
      x: canvas.midX - width / 2 + shape.shift, y: canvas.minY + shape.frame.minY, width: width,
      height: height
    ).insetBy(dx: inset, dy: inset)
    guard !shape.capsule else {
      return RoundedRectangle(
        cornerRadius: max(min(shape.bottom, rect.height / 2) - inset, 0), style: .continuous
      )
      .path(in: rect)
    }
    let ear = min(shape.ear, rect.width / 4, rect.height / 2)
    let bottom = min(shape.bottom, (rect.width - ear * 2) / 2, rect.height - ear)
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
