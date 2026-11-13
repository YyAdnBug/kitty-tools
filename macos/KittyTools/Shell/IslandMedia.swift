// 刘海岛上的正在播放（2026-11-13 刘海岛扩展第 2 期，拍板 E2）：耳朵上的封面 + 跳动条、点耳朵展开的播放卡片、那一张里的一行。
// 数据是 Island.Media（Shell/NowPlaying.swift 给）。画在岛的黑底上（同 Island 的深色、字号刻度）。
// 跳动条是图层动画（CABasicAnimation，渲染服务做、本进程不逐帧算）：放歌时一挂几个小时，Whisker §8 循环只动变换、不用 TimelineView；
// 只在在播且速率 > 0 时动，暂停 / 缓冲停住，减弱动态效果时不动。进度条和时间只在卡片开着时每秒推一次（TimelineView）。
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        TimelineView(.periodic(from: .now, by: 1)) { context in
          progress(at: context.date)
        }
      }
      IslandTransport(media: media, size: 18)
        .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 18)
    .padding(.top, 10)
    .padding(.bottom, 14)
    .frame(width: 340)
  }

  /// 进度：已播 · 细条 · 总长（11 pt 等宽数字）；细条底 white 0.18、填强调色
  private func progress(at date: Date) -> some View {
    let snapshot = media.snapshot
    let duration = snapshot.duration ?? 0
    let position = NowPlaying.position(snapshot, at: date) ?? 0
    let fraction = duration > 0 ? position / duration : 0
    return HStack(spacing: 8) {
      time(position)
      Capsule().fill(.white.opacity(0.18))
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Rectangle().fill(IslandLeading.tint(.info))
              .frame(width: proxy.size.width * min(max(fraction, 0), 1))
          }
        }
        .clipShape(Capsule())
        .frame(height: 4)
        .animation(reduceMotion ? nil : .linear(duration: 1), value: fraction)
      time(duration)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("播放到 \(Self.clock(position))，共 \(Self.clock(duration))")
  }

  /// 秒 → 「1:02:03」：夹在 0…99:59:59（快照在收的时候夹过，这里再兜一层：Int(Double) 越界会直接闪退）
  static func clock(_ seconds: Double) -> String {
    ScreenRecorder.clock(Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999)))
  }

  private func time(_ seconds: Double) -> some View {
    Text(Self.clock(seconds))
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
