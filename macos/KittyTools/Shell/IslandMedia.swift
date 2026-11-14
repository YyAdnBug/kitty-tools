// 刘海岛上的正在播放（2026-11-13 刘海岛扩展第 2 期，拍板 E2）：耳朵上的封面 + 跳动条、点耳朵 / 点刘海展开的播放卡片
// （2026-11-14 起那一张里不再有它的一行）。
// 数据是 Island.Media（Shell/NowPlaying.swift 给）。画在岛的黑底上（同 Island 的深色、字号刻度）。
// 跳动条是图层动画（CABasicAnimation，渲染服务做、本进程不逐帧算）：放歌时一挂几个小时，Whisker §8 循环只动变换、不用 TimelineView；
// 只在在播且速率 > 0 时动，暂停 / 缓冲停住，减弱动态效果时不动。进度条和时间只在卡片开着时每秒推一次（TimelineView）；
// 这个 App 支持跳时进度条能拖、能点着跳（IslandScrubber）。
// 上一首 / 下一首按快照里的 canPrevious / canNext 灰掉；两个都没有、又能跳的源（Chrome 里单个视频、播客）换成后退 /
// 前进 15 秒。点封面切到放歌的那个 App。
// 以 Alcove 为准的那一轮（2026-11-13）：跳动条和进度条跟封面的主色（ArtworkTint，换封面才算一次）；双指左右滑切歌时
// 卡片的封面上闪一个箭头（IslandSkipArrow；耳朵露着时是岛往一侧伸一下、箭头出在伸出的那一截里，2026-11-14）；指针在岛上时右耳的跳动条换成播放 / 暂停（IslandWings）。

import SwiftUI

/// 封面：圆角方块（色块的圆角，边长 × 0.225）；没有封面（网页视频刚换片的头两秒）是放歌那个 App 的图标，再没有是音符。
/// **换了一张封面时翻面**（2026-11-14 照 Alcove 的实录）：旧的那张绕竖轴转到侧立（0.14 s），换成新的从另一侧转回来
/// （0.32 s，带一点弹）。只在两张都是封面、封面的编号变了时翻（同一张重新解出来、封面晚到不翻）；减弱动态效果时直接换
struct IslandMediaArt: View {
  let media: Island.Media
  let size: CGFloat
  /// 翻到一半时还画着的旧封面
  @State private var held: NSImage?
  @State private var angle = 0.0
  @State private var seen: String?
  @State private var flip: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(media: Island.Media, size: CGFloat) {
    self.media = media
    self.size = size
    _seen = State(initialValue: media.snapshot.artworkID)
  }

  var body: some View {
    Group {
      if let artwork = held ?? media.artwork {
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
    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    .accessibilityHidden(true)
    .onChange(of: media.artwork) { old, new in
      let id = media.snapshot.artworkID
      defer { seen = id }
      guard Self.flips(from: seen, to: id, had: old != nil, has: new != nil), !reduceMotion
      else { return }
      flip?.cancel()
      // 上一次还没翻完又来一张：接着画正画着的那张（不闪一下中间那张）
      held = held ?? old
      flip = Task {
        withAnimation(.easeIn(duration: 0.14)) { angle = 90 }
        try? await Task.sleep(for: .milliseconds(140))
        // 被下一次换封面打断：状态归新的那一次管，这里不碰
        guard !Task.isCancelled else { return }
        // 侧立的那一刻换成新的、摆到另一侧（不做动画），下一帧再转回来
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
          held = nil
          angle = -90
        }
        try? await Task.sleep(for: .milliseconds(20))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 0.32, bounce: 0.3)) { angle = 0 }
      }
    }
    .onDisappear { flip?.cancel() }
  }

  /// 换封面时翻不翻（纯函数）：前后都有封面、编号变了才翻
  static func flips(from seen: String?, to id: String?, had: Bool, has: Bool) -> Bool {
    had && has && seen != id
  }
}

/// 右耳、播放卡片右上角的跳动条：5 根、宽 2、间隔 2，最高 14，以中线为轴上下对称地长（波形的样子，中间高两头矮；
/// 2026-11-14 以 Alcove 为准：原来是 4 根从底边往上长的均衡器）
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
  static let size = CGSize(width: 5 * 2 + 4 * 2, height: 14)
  /// 每根停着时多高（占最高的几成；暂停 / 缓冲时矮一截，在播时的静止样子——减弱动态效果、截图自检——高一截）、
  /// 动起来一程多久（各不一样，看着不齐步）
  private static let rest: [CGFloat] = [0.2, 0.3, 0.42, 0.3, 0.2]
  private static let lively: [CGFloat] = [0.42, 0.78, 1, 0.64, 0.36]
  private static let durations: [CFTimeInterval] = [0.52, 0.71, 0.46, 0.63, 0.57]
  private var bars: [CALayer] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for index in 0..<5 {
      let bar = CALayer()
      bar.cornerRadius = 1
      bar.frame = CGRect(x: CGFloat(index) * 4, y: 0, width: 2, height: Self.size.height)
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
      bounce.fromValue = 0.22
      bounce.toValue = Self.lively[index] * 0.5 + 0.5
      bounce.duration = Self.durations[index]
      bounce.autoreverses = true
      bounce.repeatCount = .infinity
      bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      bounce.timeOffset = Self.durations[index] * Double(index) * 0.37
      bar.add(bounce, forKey: "bounce")
    }
  }
}

/// 点耳朵展开的播放卡片（2026-11-14 以 Alcove 为准重排）：封面 52（点了切到那个 App）+ 歌名 / 艺人 · App，右上角是输出设备的
/// 图标和跳动条；进度条和时间（右边写还剩多久）；一行大的播放控制，随机、循环靠两头。没有 ×：指针离开、双指往上滑、
/// 点卡片外面都收（Island.click），读屏有「退出」动作
struct IslandMediaCard: View {
  let island: Island
  let media: Island.Media
  /// 截图自检：进度条摆成正拖到这一秒的样子
  var staged: Double?
  /// 截图自检：摆成音量滑杆开着、音量是这么多的样子（不读本机的输出设备）
  var stagedVolume: Double?
  /// 输出设备的图标；nil = 这个设备调不了音量，不出那个按钮。卡片出来时读一次
  @State private var output: String?
  /// 进度那一行换成了音量滑杆（值 = 打开那一刻读到的音量：滑杆第一帧就在对的位置）；nil = 没开
  @State private var volume: Double?

  var body: some View {
    let snapshot = media.snapshot
    let volumeOpen = volume != nil || stagedVolume != nil
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        // 同岛上别的打开类按钮：先收卡片再切（刚换内容 0.3 s 内的点不算）
        Button {
          island.perform(Island.Action("切到 App", opens: true, run: media.open))
        } label: {
          IslandMediaArt(media: media, size: 52)
            .overlay { IslandSkipArrow(skip: island.skip, size: 52) }
        }
        .buttonStyle(IslandButtonStyle())
        .accessibilityLabel("切到\(Island.Media.appLabel(snapshot))")
        VStack(alignment: .leading, spacing: 2) {
          // 按字认：换歌时整行重来（不然新歌名有一帧画在上一首滚到尾的位置）
          IslandMarquee(
            text: snapshot.title, font: .system(size: 14, weight: .semibold),
            color: .white.opacity(0.95)
          )
          .id(snapshot.title)
          IslandMarquee(
            text: Island.Media.byline(snapshot), font: .system(size: 12),
            color: .white.opacity(0.55)
          )
          .id(Island.Media.byline(snapshot))
        }
        Spacer(minLength: 12)
        HStack(spacing: 10) {
          if let output = stagedVolume == nil ? output : "speaker.wave.2.fill" {
            // 输出设备的图标（扬声器、耳机、显示器……）：点了进度那一行换成输出音量的滑杆，再点换回来
            Button {
              volume = volume == nil ? OutputVolume.read() : nil
            } label: {
              Image(systemName: output)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(volumeOpen ? 0.95 : 0.5))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("输出音量")
          }
          IslandBars(
            moving: snapshot.isPlaying && snapshot.rate > 0,
            color: media.tint ?? NSColor(IslandLeading.tint(.info))
          )
          .accessibilityHidden(true)
        }
        // 在封面那么高的框里靠上、往下让 4（Alcove 的波形在右上角）
        .padding(.top, 4)
        .frame(height: 52, alignment: .top)
      }
      if volumeOpen {
        IslandVolume(
          island: island, tint: media.tint, initial: stagedVolume ?? volume ?? 0,
          staged: stagedVolume != nil)
      } else if (snapshot.duration ?? 0) > 0, snapshot.elapsed != nil {
        // 有时长（直播之类报 0 的不画）、有进度才画
        IslandScrubber(island: island, media: media, staged: staged)
      }
      IslandTransport(media: media, size: 26)
        .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 14)
    .frame(width: 360)
    // 没有 ×：读屏用「退出」收
    .accessibilityAction(.escape) { island.close() }
    // 摆出来的岛（截图自检、单测）不读本机的输出设备：图出来的样子不能跟着这台机器插没插耳机变。
    // onAppear（不是 task）：第一帧就有那个图标，不晚一帧冒出来把歌名挤窄
    .onAppear {
      if !island.isStaged { output = OutputVolume.read() == nil ? nil : OutputVolume.symbol() }
    }
  }

  /// 秒 → 「1:02:03」：夹在 0…99:59:59（快照在收的时候夹过，这里再兜一层：Int(Double) 越界会直接闪退）
  static func clock(_ seconds: Double) -> String {
    ScreenRecorder.clock(Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999)))
  }
}

/// 细条 + 填充 + 圆点（进度条、音量滑杆共用）：底 white 0.18，填封面的主色（没有就强调色）；lifted 时细条从 5 变 7 pt、
/// 露出 11 pt 的白圆点，行高不变。两条动画各管各的属性（叠在同一棵子树上时里面那条全赢）：push 管填充的宽和圆点的位置，
/// lift 管细条的高和圆点的显隐
struct IslandTrack: View {
  let fraction: Double
  let lifted: Bool
  let tint: NSColor?
  let push: Animation?
  let lift: Animation?

  var body: some View {
    Capsule().fill(.white.opacity(0.18))
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Rectangle().fill(tint.map { Color(nsColor: $0) } ?? IslandLeading.tint(.info))
            .frame(width: proxy.size.width * fraction)
            .animation(push, value: fraction)
        }
      }
      .clipShape(Capsule())
      .frame(height: lifted ? 7 : 5)
      .animation(lift, value: lifted)
      // 行高不跟着细条变粗变
      .frame(height: 7)
      .overlay {
        GeometryReader { proxy in
          Circle().fill(.white)
            .frame(width: 11, height: 11)
            .animation(lift) { $0.scaleEffect(lifted ? 1 : 0.4).opacity(lifted ? 1 : 0) }
            .position(x: proxy.size.width * fraction, y: proxy.size.height / 2)
            .animation(push, value: fraction)
        }
        .allowsHitTesting(false)
      }
  }
}

/// 音量 / 亮度提示的符号：喇叭的波纹跟着格数一格格亮起来（符号的可变值；太阳这个符号没有可变的层，是静的——
/// macOS 27 实测），静音换成划掉的喇叭（原地替换）
struct IslandLevelSymbol: View {
  let level: Island.Level
  let size: CGFloat

  var body: some View {
    let muted = level.kind == .volume && (level.muted || level.fraction <= 0)
    Image(
      systemName: level.kind == .volume
        ? (muted ? "speaker.slash.fill" : "speaker.wave.3.fill") : level.symbol,
      variableValue: level.kind == .device ? 1 : level.shown
    )
    .font(.system(size: size, weight: .semibold))
    .foregroundStyle(.white.opacity(muted ? 0.55 : 0.95))
    .contentTransition(.symbolEffect(.replace))
    .animation(Style.Motion.snap.animation(), value: muted)
  }
}

/// 音量 / 亮度提示的细条：4 pt 高的胶囊，白色填充（静音时整条暗着）；条跟着键走得很快（一秒十几格），用 0.08 秒的线性跟上
struct IslandLevelBar: View {
  let level: Island.Level
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Capsule().fill(.white.opacity(0.22))
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule().fill(.white)
            .frame(width: max(proxy.size.width * level.shown, level.shown > 0 ? 4 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level.shown)
        }
      }
      .frame(height: 4)
  }
}

/// 按音量键 / 亮度键时，刘海屏上的样子（2026-11-14 以 Alcove 为准：原来是从刘海往下掉一行）：岛不往下长，只在刘海两边各
/// 伸出 Island.levelWing（90）、和刘海一样高——左边符号 + 「音量」/「亮度」/「静音」，右边一根 68 pt 的细条。约 2.2 秒缩回去。
/// 从耳朵过来、音量换亮度、收回耳朵时岛都先捏回刘海再长出来（Island.pinched）；两边的东西贴着形体的边跟着走
/// （Island.ride）
struct IslandLevelWings: View {
  let level: Island.Level
  let notchWidth: CGFloat
  let notchHeight: CGFloat
  @Environment(\.islandLevelRide) private var ride

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 6) {
        // 电源的提示左边只有一句话，没有图标（同 Alcove 的「Charging」）
        if level.kind != .device || level.glyph != nil {
          IslandLevelSymbol(level: level, size: 14).frame(width: 22)
        }
        Text(level.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.95))
          .lineLimit(1)
          .fixedSize()
      }
      .padding(.leading, level.kind == .device && level.glyph == nil ? 13 : 11)
      .frame(width: Island.levelWing, alignment: .leading)
      // 不再套动画：见 IslandWings
      .animation(nil) { $0.offset(x: ride) }
      Color.clear.frame(width: notchWidth)
      Group {
        if level.kind == .device {
          // 耳机连上、电源：电量（还没读到时空着，读到了原地出来）
          IslandBattery(fraction: level.battery, tone: level.tone)
        } else {
          IslandLevelBar(level: level).frame(width: 68)
        }
      }
      .padding(.trailing, 12)
      .frame(width: Island.levelWing, alignment: .trailing)
      .animation(nil) { $0.offset(x: -ride) }
    }
    .frame(height: notchHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(level.reading.label)
    .accessibilityValue(level.reading.value)
  }
}

/// 带电量的提示右边那一截（2026-11-14 照 Alcove 的截图：「Charging　99% 🔋」）：百分比（13 pt semibold 等宽）+ 电池的
/// 系统符号（照电量分五档），两样同一个颜色——好着是绿的、低了是红的、平常是白的。还没读到时什么都不画
struct IslandBattery: View {
  let fraction: Double?
  var tone = Island.Level.Tone.good

  var body: some View {
    HStack(spacing: 6) {
      if let fraction {
        Text("\(Int((fraction * 100).rounded()))%")
          .font(.system(size: 13, weight: .semibold).monospacedDigit())
          .lineLimit(1)
          .fixedSize()
        Image(systemName: Self.symbol(fraction))
          .font(.system(size: 16, weight: .medium))
          .transition(.opacity)
      }
    }
    .foregroundStyle(color)
    .animation(Style.Motion.snap.animation(), value: fraction == nil)
  }

  private var color: Color {
    switch tone {
    case .good: Color(nsColor: .systemGreen)
    case .low: Color(nsColor: .systemRed)
    case .plain: .white.opacity(0.95)
    }
  }

  /// 电池的符号照电量分五档（纯函数）
  nonisolated static func symbol(_ fraction: Double) -> String {
    switch fraction {
    case ..<0.125: "battery.0percent"
    case ..<0.375: "battery.25percent"
    case ..<0.625: "battery.50percent"
    case ..<0.875: "battery.75percent"
    default: "battery.100percent"
    }
  }
}

extension Island.Level {
  /// 读屏里念什么：音量 / 亮度是名字 + 百分比；耳机是「已连接，名字」+ 电量（没读到就没有）
  var reading: (label: String, value: String) {
    guard kind == .device else { return (title, "\(Int((shown * 100).rounded()))%") }
    return (
      [title, label].compactMap { $0 }.joined(separator: "，"),
      battery.map { "电量 \(Int(($0 * 100).rounded()))%" } ?? ""
    )
  }
}

/// 按音量键 / 亮度键时，没有刘海的屏上的那一行（MediaKeys → Island.showLevel）：符号（13 pt）· 细条（160 宽）· 百分比。
/// 同提示那一行的高度
struct IslandLevelRow: View {
  let level: Island.Level

  var body: some View {
    HStack(spacing: 10) {
      if level.kind != .device || level.glyph != nil {
        IslandLevelSymbol(level: level, size: 13).frame(width: 24)
      }
      if level.kind == .device {
        // 耳机连上：「已连上 名字」+ 电量；电源：那句话 + 电量
        Text(level.label.map { "已连上\($0)" } ?? level.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.95))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 200, alignment: .leading)
          .fixedSize(horizontal: true, vertical: false)
        IslandBattery(fraction: level.battery, tone: level.tone)
      } else {
        IslandLevelBar(level: level).frame(width: 160)
        Text("\(Int((level.shown * 100).rounded()))%")
          .font(.system(size: 12, weight: .semibold).monospacedDigit())
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
          .frame(width: 40, alignment: .trailing)
      }
    }
    .frame(height: Island.chin)
    .padding(.horizontal, 18)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(level.reading.label)
    .accessibilityValue(level.reading.value)
  }
}

/// 播放卡片上的输出音量（以 Alcove 为准的那一轮 B3）：点卡片右上角的设备图标，进度那一行换成它——喇叭 · 滑杆 · 百分比。
/// 拖着就改系统的输出音量（OutputVolume，公开的 CoreAudio；不拦按键，音量键照旧是系统自己的提示），每秒读一次跟上
/// 音量键。再点一下设备图标、或者卡片收起就换回进度——不自己到点换回：那一行在指针底下原地换成进度条，下一下点击
/// 就成了误跳进度（评审 2）。读屏里是可调的（一下 5%）
struct IslandVolume: View {
  let island: Island
  let tint: NSColor?
  /// 截图自检：不读、不写本机的音量
  let staged: Bool
  @State private var level: Double
  @GestureState private var dragging: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// initial：打开那一刻的音量（调用方读好给进来，第一帧就在对的位置）
  init(island: Island, tint: NSColor?, initial: Double, staged: Bool = false) {
    self.island = island
    self.tint = tint
    self.staged = staged
    _level = State(initialValue: min(max(initial, 0), 1))
  }

  var body: some View {
    let shown = dragging ?? level
    HStack(spacing: 8) {
      Image(systemName: shown <= 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.5))
        .frame(width: 22)
      IslandTrack(
        fraction: shown, lifted: true, tint: tint, push: nil,
        lift: Style.Motion.snap.animation(reduced: reduceMotion)
      )
      .overlay {
        GeometryReader { proxy in
          Color.clear.contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0)
                .updating($dragging) { value, state, _ in
                  state = IslandScrubber.seconds(
                    at: value.location.x, width: proxy.size.width, duration: 1)
                })
        }
        .frame(height: 18)
      }
      Text("\(Int((shown * 100).rounded()))%")
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
        .frame(width: 34, alignment: .trailing)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("输出音量")
    .accessibilityValue("\(Int((shown * 100).rounded()))%")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: change(to: level + 0.05)
      case .decrement: change(to: level - 0.05)
      @unknown default: break
      }
    }
    .onChange(of: dragging) { old, new in
      island.holdPointer(new != nil)
      guard let new else { return }
      if IslandScrubber.hitEnd(from: old, to: new, duration: 1) { island.haptic(.levelChange) }
      change(to: new)
    }
    .onDisappear { island.holdPointer(false) }
    // 每秒读一次（按了音量键滑杆跟上）；拖着时不读
    .task {
      guard !staged else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if dragging == nil, let now = OutputVolume.read() { level = now }
      }
    }
  }

  private func change(to value: Double) {
    level = min(max(value, 0), 1)
    if !staged { OutputVolume.set(level) }
  }
}

/// 播放卡片上的进度：已播 · 细条 · 还剩多久（「-0:55」，11 pt 等宽数字；2026-11-14 以 Alcove 为准，原来写总长）；细条底
/// white 0.18、填强调色，卡片开着时每秒推一次。
/// 这个 App 支持跳（快照的 canSeek）时细条能拖、能点着跳（2026-11-13）：指针在卡片上时细条从 5 变 7 pt 粗、露出一个
/// 11 pt 的白圆点；按下就跟手（不做动画、不被每秒的刷新拽走，左边的时间跟着变），松手才发一次命令——拖的路上不发，
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
    // 拖到头 / 尾：触控板一下
    .onChange(of: dragging) { old, new in
      if Self.hitEnd(from: old, to: new, duration: media.snapshot.duration ?? 0) {
        island.haptic(.levelChange)
      }
    }
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
      time(IslandMediaCard.clock(position))
      IslandTrack(fraction: fraction, lifted: lifted, tint: media.tint, push: push, lift: lift)
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
      time(Self.remaining(position, of: duration))
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

  /// 拖着拖着到了头或者尾（上一下还不在那一头）
  static func hitEnd(from old: Double?, to new: Double?, duration: Double) -> Bool {
    guard let new, duration > 0, new <= 0 || new >= duration else { return false }
    guard let old else { return true }
    return new <= 0 ? old > 0 : old < duration
  }

  /// 填到几成：夹在 0…1
  static func fraction(_ position: Double, of duration: Double) -> Double {
    guard duration > 0, position.isFinite else { return 0 }
    return min(max(position / duration, 0), 1)
  }

  /// 右边那个时间：还剩多久，前面带负号（剩 0 也带：宽度不跳）
  static func remaining(_ position: Double, of duration: Double) -> String {
    "-" + IslandMediaCard.clock(max(duration - position, 0))
  }

  private func time(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11).monospacedDigit())
      .foregroundStyle(.white.opacity(0.5))
      .lineLimit(1)
      .fixedSize()
  }
}

/// 播放卡片上的那一行控制：上一首、播放 / 暂停、下一首（白色实心符号，播放 / 暂停 26 pt、两边 21，不支持的灰掉），
/// 随机、循环 14 pt 靠卡片两头（2026-11-14 以 Alcove 为准：原来 18 / 15 / 12 挤在中间）。这个 App 随机、循环都不支持就不占
/// 位置，只支持一样时另一头空着（三个主按钮照旧居中）
struct IslandTransport: View {
  let media: Island.Media
  /// 播放 / 暂停的字号
  let size: CGFloat

  var body: some View {
    let snapshot = media.snapshot
    let showsModes = snapshot.shuffle != nil || snapshot.repeatMode != nil
    HStack(spacing: 0) {
      if showsModes {
        if let shuffle = snapshot.shuffle {
          mode(
            "shuffle", label: "随机播放", value: shuffle == 1 ? "关" : "开", on: shuffle != 1,
            alignment: .leading
          ) {
            media.setShuffle(NowPlaying.nextShuffle(shuffle))
          }
        } else {
          modeSpace
        }
        Spacer(minLength: 0)
      }
      main(snapshot)
      if showsModes {
        Spacer(minLength: 0)
        if let repeatMode = snapshot.repeatMode {
          mode(
            repeatMode == 2 ? "repeat.1" : "repeat", label: "循环播放",
            value: repeatMode == 1 ? "关" : repeatMode == 2 ? "单曲循环" : "列表循环",
            on: repeatMode != 1, alignment: .trailing
          ) { media.setRepeat(NowPlaying.nextRepeat(repeatMode)) }
        } else {
          modeSpace
        }
      }
    }
  }

  /// 中间三个
  private func main(_ snapshot: NowPlayingSnapshot) -> some View {
    let jumps = Self.usesJumps(snapshot)
    let side = size - 5
    return HStack(spacing: size) {
      if jumps {
        button("gobackward.15", label: "后退 15 秒", size: side, enabled: true) { jump(-15) }
      } else {
        button("backward.fill", label: "上一首", size: side, enabled: snapshot.canPrevious) {
          media.send(.previous)
        }
      }
      button(
        snapshot.isPlaying ? "pause.fill" : "play.fill", label: snapshot.isPlaying ? "暂停" : "播放",
        size: size, enabled: true
      ) { media.send(.toggle) }
      if jumps {
        button("goforward.15", label: "前进 15 秒", size: side, enabled: true) { jump(15) }
      } else {
        button("forward.fill", label: "下一首", size: side, enabled: snapshot.canNext) {
          media.send(.next)
        }
      }
    }
  }

  /// 随机 / 循环：14 pt 的符号，符号贴着卡片内容的边（alignment）；开着染封面的主色（没有就强调色）、底下一个小圆点，
  /// 关着 white 0.45。点了不自己变：等播放器报回来
  private func mode(
    _ symbol: String, label: String, value: String, on: Bool, alignment: Alignment,
    run: @escaping () -> Void
  ) -> some View {
    let tint = media.tint.map { Color(nsColor: $0) } ?? IslandLeading.tint(.info)
    return Button(action: run) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(on ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.45)))
        .contentTransition(.symbolEffect(.replace))
        .animation(Style.Motion.snap.animation(), value: symbol)
        .overlay(alignment: .bottom) {
          Circle().fill(tint).frame(width: 3, height: 3).offset(y: 6).opacity(on ? 1 : 0)
        }
        .frame(width: 36, height: size + 10, alignment: alignment)
        .contentShape(Rectangle())
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(label)
    .accessibilityValue(value)
  }

  private var modeSpace: some View {
    Color.clear.frame(width: 36, height: size + 10).accessibilityHidden(true)
  }

  /// 上一首 / 下一首都用不了、又能跳的源（Chrome 里单个视频、播客）：两个灰着的按钮换成后退 / 前进 15 秒
  static func usesJumps(_ snapshot: NowPlayingSnapshot) -> Bool {
    !snapshot.canPrevious && !snapshot.canNext && snapshot.elapsed != nil
      && NowPlaying.seekTarget(0, in: snapshot) != nil
  }

  /// 从此刻的位置挪几秒（夹进这一首里由 NowPlaying.seek 管）
  private func jump(_ seconds: Double) {
    media.seek((NowPlaying.position(media.snapshot, at: .now) ?? 0) + seconds)
  }

  /// 播放 ↔ 暂停换符号时原地替换（系统的符号过渡），不是硬切
  private func button(
    _ symbol: String, label: String, size: CGFloat, enabled: Bool, run: @escaping () -> Void
  ) -> some View {
    Button(action: run) {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.3))
        .contentTransition(.symbolEffect(.replace))
        // 符号替换只在带动画的事务里走（快照是播放器报回来才换的，不在 withAnimation 里）
        .animation(Style.Motion.snap.animation(), value: symbol)
        .frame(width: size + 14, height: size + 10)
        .contentShape(Rectangle())
    }
    .buttonStyle(IslandButtonStyle())
    .disabled(!enabled)
    .accessibilityLabel(label)
  }
}

/// 一行字放不下时慢慢滚（以 Alcove 为准的那一轮 B5；只有播放卡片上的歌名、艺人用）：停 1.5 秒 → 匀速滚到尾（每秒 30 pt）→
/// 停 1.5 秒 → 滚回开头，往返。放得下、减弱动态效果时就是普通的一行（截断加省略号）。卡片开着才有它，收起就不滚了
/// （指针停在卡片上时卡片不收，会一直滚：SwiftUI 的平移动画，本进程在算，开销看 HANDTEST「第 2 批」12）
struct IslandMarquee: View {
  let text: String
  let font: Font
  let color: Color
  @State private var textWidth: CGFloat = 0
  @State private var boxWidth: CGFloat = 0
  @State private var atEnd = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let overflow = Self.overflow(text: textWidth, box: boxWidth)
    let scrolls = overflow > 0 && !reduceMotion
    // 底下那一行定高度和能用的宽度（截断着；要滚时藏起来）；上面那一行不截断、整行平移，被这一行的框裁掉
    Text(text)
      .font(font)
      .foregroundStyle(color)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .opacity(scrolls ? 0 : 1)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        boxWidth = $0
      }
      .overlay(alignment: .leading) {
        Text(text)
          .font(font)
          .foregroundStyle(color)
          .lineLimit(1)
          .fixedSize()
          .onGeometryChange(for: CGFloat.self) {
            $0.size.width
          } action: {
            textWidth = $0
          }
          .offset(x: scrolls && atEnd ? -overflow : 0)
          .opacity(scrolls ? 1 : 0)
          .accessibilityHidden(true)
      }
      .clipped()
      // 读屏只念一遍整句（滚动时底下那行藏着、上面那行不给读屏）
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
      .task(id: Run(text: text, overflow: scrolls ? overflow : 0)) {
        atEnd = false
        guard scrolls else { return }
        let travel = Double(overflow) / 30
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1.5))
          guard !Task.isCancelled else { return }
          withAnimation(.linear(duration: travel)) { atEnd.toggle() }
          try? await Task.sleep(for: .seconds(travel))
        }
      }
  }

  /// 这一轮滚动由什么定：字换了、多出来的长度变了就从头来
  private struct Run: Equatable {
    var text: String
    var overflow: CGFloat
  }

  /// 字比框多出多少（不到 1 pt 当放得下：量出来的宽度有零头）
  static func overflow(text: CGFloat, box: CGFloat) -> CGFloat {
    let extra = text - box
    return box > 0 && extra >= 1 ? extra : 0
  }
}

/// 双指左右滑切了歌：封面上闪一下箭头（暗一层底 + 白色的下一首 / 上一首符号，0.5 秒）。只看 skip 的次数变没变
struct IslandSkipArrow: View {
  let skip: Island.Skip?
  /// 封面的边长
  let size: CGFloat
  @State private var shown = false
  /// 已经闪过的那一次：视图建出来时已有的那一次不闪（先在耳朵上滑过、再展开卡片）
  @State private var seen: Int?

  init(skip: Island.Skip?, size: CGFloat) {
    self.skip = skip
    self.size = size
    _seen = State(initialValue: skip?.count)
  }

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
      .fill(.black.opacity(0.45))
      .overlay {
        Image(systemName: skip?.forward ?? true ? "forward.fill" : "backward.fill")
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(.white)
      }
      .opacity(shown ? 1 : 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .animation(Style.Motion.snap.animation() ?? .easeInOut(duration: 0.15), value: shown)
      .task(id: skip?.count) {
        guard let skip, skip.count != seen else { return }
        seen = skip.count
        shown = true
        try? await Task.sleep(for: .milliseconds(500))
        // 半秒内又滑了一次：这一个任务被取消，收掉的事交给新的那个
        guard !Task.isCancelled else { return }
        shown = false
      }
  }
}

/// 封面的主色：跳动条、进度条跟它走（Alcove 收起时的波形就是这样，颜色来自内容）。换封面才算一次：256 px 的封面画成
/// 24 × 24 再数像素，不常驻、不逐帧
nonisolated enum ArtworkTint {
  /// 一块 RGBA8 像素 → 主色（色相、饱和度、亮度都是 0…1）。按色相分 12 桶，每个像素按「够不够鲜艳」加权（最大和最小
  /// 分量的差），最重的那一桶里取加权平均，再收拾成岛的黑底上看得清的样子：饱和度夹在 0.5…0.8、亮度至少 0.9
  /// （蓝到紫那一段 0.5…0.55、亮度 1）。
  /// 整张图太灰、太暗（黑白封面）是 nil，调用方用强调色
  static func dominant(rgba: [UInt8]) -> (hue: Double, saturation: Double, brightness: Double)? {
    var weights = [Double](repeating: 0, count: 12)
    var reds = weights
    var greens = weights
    var blues = weights
    var pixels = 0.0
    for index in stride(from: 0, to: rgba.count - 3, by: 4) {
      let red = Double(rgba[index]) / 255
      let green = Double(rgba[index + 1]) / 255
      let blue = Double(rgba[index + 2]) / 255
      pixels += 1
      let high = max(red, green, blue)
      let delta = high - min(red, green, blue)
      // 太暗、太灰的像素不算
      guard high > 0.15, delta / high > 0.2 else { continue }
      // 桶的边界错开半格：红色在 0° 两边（0.99 和 0.01）落进同一桶
      let bucket = Int(hue(red, green, blue, high: high, delta: delta) * 12 + 0.5) % 12
      weights[bucket] += delta
      reds[bucket] += red * delta
      greens[bucket] += green * delta
      blues[bucket] += blue * delta
    }
    guard pixels > 0, let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
      weights[best] / pixels > 0.02
    else { return nil }
    let red = reds[best] / weights[best]
    let green = greens[best] / weights[best]
    let blue = blues[best] / weights[best]
    let high = max(red, green, blue)
    let delta = high - min(red, green, blue)
    guard high > 0, delta > 0 else { return nil }
    let main = hue(red, green, blue, high: high, delta: delta)
    // 蓝到紫那一段本身就暗（纯蓝在黑底上对比度不到 3:1）：饱和度压到 0.55、亮度提满
    let dim = (0.58...0.8).contains(main)
    return (main, min(max(delta / high, 0.5), dim ? 0.55 : 0.8), dim ? 1 : max(high, 0.9))
  }

  /// 色相 0…1（delta > 0）
  private static func hue(
    _ red: Double, _ green: Double, _ blue: Double, high: Double, delta: Double
  )
    -> Double
  {
    let sixth: Double
    if high == red {
      sixth = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
    } else if high == green {
      sixth = (blue - red) / delta + 2
    } else {
      sixth = (red - green) / delta + 4
    }
    return (sixth < 0 ? sixth + 6 : sixth) / 6
  }

  /// 封面 → 主色；画不出来、太灰是 nil
  static func color(of image: NSImage) -> NSColor? {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let side = 24
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .low
      context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn, let main = dominant(rgba: pixels) else { return nil }
    return NSColor(
      hue: main.hue, saturation: main.saturation, brightness: main.brightness, alpha: 1)
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
