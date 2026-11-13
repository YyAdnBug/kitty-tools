// 刘海岛上的正在播放（2026-11-13 刘海岛扩展第 2 期，拍板 E2）：耳朵上的封面 + 跳动条、点耳朵展开的播放卡片、那一张里的一行。
// 数据是 Island.Media（Shell/NowPlaying.swift 给）。画在岛的黑底上（同 Island 的深色、字号刻度）。
// 跳动条是图层动画（CABasicAnimation，渲染服务做、本进程不逐帧算）：放歌时一挂几个小时，Whisker §8 循环只动变换、不用 TimelineView；
// 只在在播且速率 > 0 时动，暂停 / 缓冲停住，减弱动态效果时不动。进度条和时间只在卡片开着时每秒推一次（TimelineView）；
// 这个 App 支持跳时进度条能拖、能点着跳（IslandScrubber）。
// 上一首 / 下一首按快照里的 canPrevious / canNext 灰掉（Chrome 里单个视频没有）；点封面切到放歌的那个 App。

import SwiftUI

/// 封面：圆角方块（色块的圆角，边长 × 0.225）；没有封面（网页视频刚换片的头两秒）是放歌那个 App 的图标，再没有是音符
struct IslandMediaArt: View {
  let media: Island.Media
  let size: CGFloat

  var body: some View {
    Group {
      if let artwork = media.artwork {
        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
      } else if let icon = media.appIcon {
        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: "music.note")
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.8))
          .frame(width: size, height: size)
          .background(.white.opacity(0.16))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    .accessibilityHidden(true)
  }
}

/// 右耳上的跳动条：4 根、宽 3、间隔 2，最高 14，从底边往上长
struct IslandBars: NSViewRepresentable {
  /// 在动（在播且速率 > 0）
  let moving: Bool
  let color: NSColor
  /// 读环境里的（不读 Style.reduceMotion）：系统开关一变 SwiftUI 就重跑 updateNSView，条跟着停 / 动
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> IslandBarsView { IslandBarsView() }

  func updateNSView(_ view: IslandBarsView, context: Context) {
    view.update(moving: moving, animate: !reduceMotion, color: color)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: IslandBarsView, context: Context)
    -> CGSize?
  {
    IslandBarsView.size
  }
}

final class IslandBarsView: NSView {
  static let size = CGSize(width: 4 * 3 + 3 * 2, height: 14)
  /// 每根停着时多高（占最高的几成；暂停 / 缓冲时矮一截，在播时的静止样子——减弱动态效果、截图自检——高一截）、
  /// 动起来一程多久（各不一样，看着不齐步）
  private static let rest: [CGFloat] = [0.35, 0.6, 0.45, 0.3]
  private static let lively: [CGFloat] = [0.7, 1, 0.55, 0.85]
  private static let durations: [CFTimeInterval] = [0.52, 0.71, 0.46, 0.63]
  private var bars: [CALayer] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for index in 0..<4 {
      let bar = CALayer()
      bar.cornerRadius = 1.5
      bar.anchorPoint = CGPoint(x: 0.5, y: 0)
      bar.frame = CGRect(x: CGFloat(index) * 5, y: 0, width: 3, height: Self.size.height)
      bar.transform = CATransform3DMakeScale(1, Self.rest[index], 1)
      layer?.addSublayer(bar)
      bars.append(bar)
    }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { Self.size }

  /// animate：要不要挂往返动画（减弱动态效果时只摆在播的静止样子）
  func update(moving: Bool, animate: Bool = true, color: NSColor) {
    // 岛固定是深色：颜色按深色那一档取（App 自己是浅色时 cgColor 会取成浅色的）
    var fill = color.cgColor
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { fill = color.cgColor }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      bar.backgroundColor = fill
      bar.transform = CATransform3DMakeScale(1, (moving ? Self.lively : Self.rest)[index], 1)
    }
    CATransaction.commit()
    // 看图层上还有没有动画（不只记一个标记）：系统摘掉了动画也能补回来
    let wanted = moving && animate
    let running = bars.first?.animation(forKey: "bounce") != nil
    guard wanted != running else { return }
    for (index, bar) in bars.enumerated() {
      bar.removeAnimation(forKey: "bounce")
      guard wanted else { continue }
      let bounce = CABasicAnimation(keyPath: "transform.scale.y")
      bounce.fromValue = 0.25
      bounce.toValue = 1
      bounce.duration = Self.durations[index]
      bounce.autoreverses = true
      bounce.repeatCount = .infinity
      bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bounce.timeOffset = Self.durations[index] * Double(index) * 0.37
      bar.add(bounce, forKey: "bounce")
    }
  }
}

/// 点耳朵展开的播放卡片：封面（点了切到那个 App）+ 歌名 / 艺人 · App + ×；进度条和时间；上一首、播放 / 暂停、下一首
struct IslandMediaCard: View {
  let island: Island
  let media: Island.Media
  /// 截图自检：进度条摆成正拖到这一秒的样子
  var staged: Double?

  var body: some View {
    let snapshot = media.snapshot
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        // 同岛上别的打开类按钮：先收卡片再切（刚换内容 0.3 s 内的点不算）
        Button {
          island.perform(Island.Action("切到 App", opens: true, run: media.open))
        } label: {
          IslandMediaArt(media: media, size: 48)
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel("切到\(Island.Media.appLabel(snapshot))")
        VStack(alignment: .leading, spacing: 2) {
          Text(snapshot.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
          Text(Island.Media.byline(snapshot))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .truncationMode(.tail)
        Spacer(minLength: 12)
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
      // 有时长（直播之类报 0 的不画）、有进度才画
      if (snapshot.duration ?? 0) > 0, snapshot.elapsed != nil {
        IslandScrubber(island: island, media: media, staged: staged)
      }
      IslandTransport(media: media, size: 18)
        .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 18)
    .padding(.top, 10)
    .padding(.bottom, 14)
    .frame(width: 340)
  }

  /// 秒 → 「1:02:03」：夹在 0…99:59:59（快照在收的时候夹过，这里再兜一层：Int(Double) 越界会直接闪退）
  static func clock(_ seconds: Double) -> String {
    ScreenRecorder.clock(Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999)))
  }
}

/// 播放卡片上的进度：已播 · 细条 · 总长（11 pt 等宽数字）；细条底 white 0.18、填强调色，卡片开着时每秒推一次。
/// 这个 App 支持跳（快照的 canSeek）时细条能拖、能点着跳（2026-11-13）：指针在卡片上时细条从 4 变 6 pt 粗、露出一个
/// 10 pt 的白圆点；按下就跟手（不做动画、不被每秒的刷新拽走，左边的时间跟着变），松手才发一次命令——拖的路上不发，
/// 播放器不会一路跟着跳。按住时告诉岛别按指针位置收卡片（Island.holdPointer）：拖过头、拖出卡片是常事。
/// 岛的窗口不接键盘，拖只靠鼠标；读屏里是可调的元素（一下挪时长的 5%、至少 5 秒）
struct IslandScrubber: View {
  let island: Island
  let media: Island.Media
  /// 截图自检摆出「正拖着」的样子（拖到第几秒）
  var staged: Double?
  /// 正拖到的位置（秒）；没在拖是 nil。手势状态：松手、手势被系统打断都自己回到 nil（不会卡在「拖着」）
  @GestureState private var dragging: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let row = bar(at: context.date)
      if media.snapshot.canSeek {
        row.accessibilityAdjustableAction(adjust)
      } else {
        row
      }
    }
    .onChange(of: dragging != nil) { _, held in island.holdPointer(held) }
    // 拖到一半卡片没了（播放器退了、被别的提示换掉）：把岛放开
    .onDisappear { island.holdPointer(false) }
  }

  /// 读屏调一下：从此刻的位置挪一步
  private func adjust(_ direction: AccessibilityAdjustmentDirection) {
    let snapshot = media.snapshot
    let step = NowPlaying.seekStep(duration: snapshot.duration ?? 0)
    let from = NowPlaying.position(snapshot, at: .now) ?? 0
    switch direction {
    case .increment: media.seek(from + step)
    case .decrement: media.seek(from - step)
    @unknown default: break
    }
  }

  private func bar(at date: Date) -> some View {
    let snapshot = media.snapshot
    let duration = snapshot.duration ?? 0
    let dragged = dragging ?? staged
    let position = dragged ?? NowPlaying.position(snapshot, at: date) ?? 0
    let fraction = Self.fraction(position, of: duration)
    let seekable = snapshot.canSeek
    let lifted = seekable && (island.isHovered || dragged != nil)
    // 两条动画各管各的属性（叠在同一棵子树上时里面那条全赢：松手在卡片外面，圆点会照 1 秒线性慢慢收，评审 5）：
    // 往前推的管填充的宽、圆点的位置——平时每秒一格（线性 1 s），拖着、点着跳时跟手不做动画；变粗的管细条的高、圆点的显隐
    let push: Animation? = dragged == nil && !reduceMotion ? .linear(duration: 1) : nil
    let lift = Style.Motion.snap.animation(reduced: reduceMotion)
    return HStack(spacing: 8) {
      time(position)
      Capsule().fill(.white.opacity(0.18))
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Rectangle().fill(IslandLeading.tint(.info))
              .frame(width: proxy.size.width * fraction)
              .animation(push, value: fraction)
          }
        }
        .clipShape(Capsule())
        .frame(height: lifted ? 6 : 4)
        .animation(lift, value: lifted)
        // 行高不跟着细条变粗变
        .frame(height: 6)
        .overlay {
          GeometryReader { proxy in
            Circle().fill(.white)
              .frame(width: 10, height: 10)
              .animation(lift) { $0.scaleEffect(lifted ? 1 : 0.4).opacity(lifted ? 1 : 0) }
              .position(x: proxy.size.width * fraction, y: proxy.size.height / 2)
              .animation(push, value: fraction)
          }
          .allowsHitTesting(false)
        }
        // 接鼠标的那一条比细条高（18 pt），好点；画在细条上面、不占行高。按歌名认：拖到一半换了歌，这一条换成新的、
        // 手势当场作废——不然松手会按新歌的时长把新歌跳到中间（评审 4）
        .overlay {
          if seekable {
            GeometryReader { proxy in
              Color.clear.contentShape(Rectangle())
                .gesture(drag(width: proxy.size.width, duration: duration))
            }
            .frame(height: 18)
            .id(snapshot.title)
          }
        }
      time(duration)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("播放进度")
    .accessibilityValue("\(IslandMediaCard.clock(position))，共 \(IslandMediaCard.clock(duration))")
    // 每秒在变：旁白光标停在上面时别每秒念一遍
    .accessibilityAddTraits(.updatesFrequently)
  }

  /// 按下就算（minimumDistance 0：点一下也是跳）；松手发命令：快照当场换成跳到的位置（NowPlaying.seek），和手势状态
  /// 回到 nil 是同一轮更新，进度条不闪回去
  private func drag(width: CGFloat, duration: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .updating($dragging) { value, state, _ in
        state = Self.seconds(at: value.location.x, width: width, duration: duration)
      }
      .onEnded { value in
        media.seek(Self.seconds(at: value.location.x, width: width, duration: duration))
      }
  }

  /// 细条上横坐标 x 的那一点是第几秒：夹在 0…时长（拖过头就是头 / 尾）；细条没宽度、时长不对是 0
  static func seconds(at x: CGFloat, width: CGFloat, duration: Double) -> Double {
    guard width > 0, duration.isFinite, duration > 0, x.isFinite else { return 0 }
    return min(max(Double(x / width), 0), 1) * duration
  }

  /// 填到几成：夹在 0…1
  static func fraction(_ position: Double, of duration: Double) -> Double {
    guard duration > 0, position.isFinite else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  private func time(_ seconds: Double) -> some View {
    Text(IslandMediaCard.clock(seconds))
      .font(.system(size: 11).monospacedDigit())
      .foregroundStyle(.white.opacity(0.5))
      .lineLimit(1)
      .fixedSize()
  }
}

/// 上一首、播放 / 暂停、下一首：白色实心符号，不支持的灰掉
struct IslandTransport: View {
  let media: Island.Media
  /// 播放 / 暂停的字号；两边小 3
  let size: CGFloat

  var body: some View {
    let snapshot = media.snapshot
    HStack(spacing: size * 1.4) {
      button("backward.fill", label: "上一首", size: size - 3, enabled: snapshot.canPrevious) {
        media.send(.previous)
      }
      button(
        snapshot.isPlaying ? "pause.fill" : "play.fill", label: snapshot.isPlaying ? "暂停" : "播放",
        size: size, enabled: true
      ) { media.send(.toggle) }
      button("forward.fill", label: "下一首", size: size - 3, enabled: snapshot.canNext) {
        media.send(.next)
      }
    }
  }

  private func button(
    _ symbol: String, label: String, size: CGFloat, enabled: Bool, run: @escaping () -> Void
  ) -> some View {
    Button(action: run) {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white.opacity(enabled ? 0.92 : 0.3))
        .frame(width: size + 12, height: size + 10)
        .contentShape(Rectangle())
    }
    .buttonStyle(IslandButtonStyle())
    .disabled(!enabled)
    .accessibilityLabel(label)
  }
}

/// 那一张里的一行（高 34）：封面（点了收起那一张、切到那个 App）、歌名 / 艺人、小一号的播放控制
struct IslandMediaRow: View {
  let media: Island.Media
  /// 同那一张里别的按钮（Island.perform：先收再跑）
  let perform: (Island.Action) -> Void

  var body: some View {
    let snapshot = media.snapshot
    HStack(spacing: 10) {
      Button {
        perform(Island.Action("切到 App", opens: true, run: media.open))
      } label: {
        IslandMediaArt(media: media, size: 22)
      }
      .buttonStyle(IslandButtonStyle())
      .accessibilityLabel("切到\(Island.Media.appLabel(snapshot))")
      VStack(alignment: .leading, spacing: 1) {
        Text(snapshot.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
        Text(Island.Media.byline(snapshot))
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.5))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      Spacer(minLength: 8)
      IslandTransport(media: media, size: 13)
    }
    .frame(height: 34)
  }
}

extension Island.Media {
  /// 第二行：艺人 · App（没有艺人只写 App）
  static func byline(_ snapshot: NowPlayingSnapshot) -> String {
    [snapshot.artist, appLabel(snapshot)].compactMap { $0 }.joined(separator: " · ")
  }

  /// 放歌的 App 叫什么：显示名，没有就用 bundle id 的最后一段
  static func appLabel(_ snapshot: NowPlayingSnapshot) -> String {
    snapshot.appName
      ?? (snapshot.parentBundleID ?? snapshot.bundleID).split(separator: ".").last.map(String.init)
      ?? snapshot.bundleID
  }
}
