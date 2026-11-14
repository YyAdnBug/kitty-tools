// 刘海岛的「活动」（2026-11-13，刘海岛扩展拍板 B1–B3、C1–C4，用户「按推荐开始」）：一直挂着的状态——录屏 / 录音中、
// 慢的长任务、一小时以内的提醒倒数、保持唤醒。和弹一下就走的提示是两回事。
// 刘海屏上收起时挂在刘海两侧的「耳朵」上（每侧 Island.wing = 36 pt：左边图标或一圈进度、右边计时 / 百分比），只露最要紧的
// 一个（B2：录制 > 长任务进度 > 保持唤醒 > 提醒倒数）；指针停上去鼓起一点，点耳朵、点刘海、往下滑都展开成它的卡片（同悬停
// 展开的样子，有停止、暂停这类按钮），再往下滑轮到下一个活动、最后是「那一张」（2026-11-14：一个刘海只有一张面；原来点刘海
// 是那一张、最上面多一行活动，B3）。提示照旧从刘海长出来盖住耳朵，收起后
// 缩回耳朵、不缩进刘海。没有刘海屏的 Mac 上不挂耳朵（H1：放进菜单栏，第 1-3 批）。
// 这里是模型、先后和读数的纯函数，耳朵上那两小块的画法；状态和窗口在 Island.swift，形体在 IslandView。
// 每秒在变的读数用 Ticker（图层滚数字，不用 numericText：每秒换一次要 7–15% CPU），只在耳朵露着时由 TimelineView 每秒推一次。
// 正在播放（刘海岛扩展第 2 期，Shell/NowPlaying.swift）也是一个活动：类别最低（.media，有别的活动时耳朵上让给别的），
// 带 media（封面、歌名、进度、发命令）；暂停一阵后不上耳朵（onWings），卡片照样轮得到（Island.rotate）；不进菜单栏那一项。
// 它的耳朵、卡片的画法在 IslandMedia.swift。

import SwiftUI

extension Island {
  struct Activity: Identifiable {
    /// 哪一类（也是先后：数大的先露，拍板 B2）
    enum Kind: Int, Comparable {
      /// event：十分钟内要开始的日程（2026-11-14）——比保持唤醒、提醒的倒数要紧（它们一挂几个小时，会议马上就到）
      case media, reminder, awake, event, progress, record

      static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 右耳上的读数
    enum Trailing: Equatable {
      /// 从这一刻起往上数（录制）
      case elapsed(since: Date)
      /// 倒数到这一刻（提醒）
      case countdown(to: Date)
      /// 做到哪了 0…1（长任务）：右耳写百分比，左耳画一圈进度
      case fraction(Double)
      /// 定死的一小段字（暂停时的「0:42」、保持唤醒的「1 小时」）
      case text(String)
      case none
    }

    /// 同一个调用方每次用同一个编号：再 set 一次 = 原地更新
    let id: String
    var kind: Kind
    /// 卡片上的标题、读屏念的：「录屏中」「正在压缩」
    var title: String
    var detail: String?
    /// 左耳和卡片前导的符号（有进度时左耳画一圈进度，不用它）；带圆底的（xxx.circle.fill）画成语气色圆底 + 白符号
    var symbol: String
    /// 颜色跟语气走（IslandLeading.tint）：录制用 .error（红），别的是 .info（强调色）。只管颜色，不抖、不弹菜单栏图标
    var tone: Tone
    var trailing: Trailing
    /// 展开的卡片上的按钮（停止、暂停 / 继续、提前结束……）；第一个是最主要的
    var actions: [Action]
    var started: Date
    /// 正在播放（kind 是 .media 时有）：耳朵、卡片上画成封面 + 歌名 + 播放控制
    var media: Media?
    /// 上不上耳朵（菜单栏那一项同）：正在播放暂停一阵后 false，卡片照样轮得到
    var onWings: Bool

    init(
      id: String, kind: Kind, title: String, detail: String? = nil, symbol: String,
      tone: Tone = .info, trailing: Trailing = .none, actions: [Action] = [],
      started: Date = .now, media: Media? = nil, onWings: Bool = true
    ) {
      self.id = id
      self.kind = kind
      self.title = title
      self.detail = detail
      self.symbol = symbol
      self.tone = tone
      self.trailing = trailing
      self.actions = actions
      self.started = started
      self.media = media
      self.onWings = onWings
    }

    /// 耳朵上露哪一个（B2）：上得了耳朵的里面，类别要紧的先；同一类后开始的先（刚开的那件事更可能是你在等的）
    static func top(_ activities: [Activity]) -> Activity? {
      activities.filter(\.onWings).max { ($0.kind, $0.started) < ($1.kind, $1.started) }
    }

    /// 右耳上的字（纯函数，单测锁住）：计时同录制 HUD（0:42、1:02:03），倒数到 0 停住，百分比取整
    static func reading(_ trailing: Trailing, now: Date) -> String? {
      switch trailing {
      case .elapsed(let since): ScreenRecorder.clock(max(Int(now.timeIntervalSince(since)), 0))
      case .countdown(let end):
        ScreenRecorder.clock(max(Int(end.timeIntervalSince(now).rounded(.up)), 0))
      case .fraction(let value): "\(Int((min(max(value, 0), 1) * 100).rounded(.down)))%"
      case .text(let text): text
      case .none: nil
      }
    }

    /// 这一个的读数每秒在变（耳朵露着时要每秒推一次）
    var ticks: Bool {
      switch trailing {
      case .elapsed, .countdown: true
      default: false
      }
    }

    var tint: Color { IslandLeading.tint(tone) }

    /// 展开成卡片时的样子（前导同提示：语气色圆底的符号）
    var content: Content {
      var fraction: Double?
      if case .fraction(let value) = trailing { fraction = value }
      return Content(
        title: title, detail: detail, tone: tone, symbol: symbol, leading: .tone, fraction: fraction
      )
    }
  }

  /// 耳朵每侧多宽（拍板 B1：不超过 36 pt，免得盖住离刘海最近的菜单栏图标）
  static let wing: CGFloat = 36

  /// 音量 / 亮度提示在刘海每侧伸出多宽、比刘海高多少（照 Alcove 的实录：每侧 108、高出 5；放得下符号 + 两个字、一根
  /// 68 pt 的细条）。比耳朵宽，会盖住离刘海最近的菜单栏图标——只有一秒多
  static let levelWing: CGFloat = 108
  static let levelDrop: CGFloat = 5

  /// 刘海两边的东西这一刻要往里挪多少，才贴着形体的边（纯函数）。它们是照「长到位」的样子排的（每侧 wing 宽）；
  /// 形体还没长到那么宽（正从刘海往两边长开、正捏回刘海）时，两边各往中间挪「形体每侧还差的那一截」——东西跟着边
  /// 一起出去、一起回来，不是停在原位被边一点点露出来 / 切掉（2026-11-14 用户：音量 / 亮度往两边展开的动画和
  /// Alcove 不一致；它的逐帧实录里图标离边一直是同一段距离）。形体比它宽（鼓起、展开成卡片）不挪；最多挪一个 wing
  nonisolated static func ride(wing: CGFloat, notch: CGFloat, shape: CGFloat) -> CGFloat {
    min(max((notch + wing * 2 - shape) / 2, 0), wing)
  }

  /// 正在播放的活动带的东西（NowPlaying 给）：快照、解好的封面、放歌那个 App 的图标（没有封面时顶上）、发命令和切到那个 App
  struct Media {
    var snapshot: NowPlayingSnapshot
    var artwork: NSImage?
    /// 封面的主色（ArtworkTint）：跳动条、进度条跟它走；没有封面、封面太灰是 nil = 用强调色
    var tint: NSColor?
    var appIcon: NSImage?
    var send: (NowPlayingCommand) -> Void
    /// 跳到这一首的第几秒（进度条）
    var seek: (Double) -> Void
    /// 换随机 / 循环的档（快照里那一样不是 nil 才画按钮）
    var setShuffle: (Int) -> Void = { _ in }
    var setRepeat: (Int) -> Void = { _ in }
    var open: () -> Void
  }
}

extension EnvironmentValues {
  /// 耳朵、音量 / 亮度提示这一刻各要往中间挪多少（Island.ride；IslandView 跟着形体的动画逐帧给）。没人给是 0
  @Entry var islandWingRide: CGFloat = 0
  @Entry var islandLevelRide: CGFloat = 0
}

/// 刘海两侧的耳朵：左边图标 / 一圈进度，中间让出刘海，右边读数。画在岛的黑底上（同 Island 的深色）
struct IslandWings: View {
  let activity: Island.Activity
  /// 刘海宽（Island.Geometry.notch 给的，真刘海 + 4）、高
  let notchWidth: CGFloat
  let notchHeight: CGFloat
  /// 指针停在刘海 / 耳朵上（岛鼓起着）：正在播放的右耳从跳动条换成播放 / 暂停，点它直接切换
  var peeking = false
  /// 刚用双指左右滑切了歌。平时岛往一侧伸一下、箭头出在伸出的那一截里（IslandView）；减弱动态效果时岛不伸，
  /// 箭头闪在左耳的封面上
  var skip: Island.Skip?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.islandWingRide) private var ride

  var body: some View {
    HStack(spacing: 0) {
      // 挪的这一下不再套动画（.animation(nil)）：ride 本身已经是逐帧给的动画中途的值，再套一层就跟不上边
      leading.frame(width: Island.wing).animation(nil) { $0.offset(x: ride) }
      Color.clear.frame(width: notchWidth)
      trailing.frame(width: Island.wing).animation(nil) { $0.offset(x: -ride) }
    }
    .frame(height: notchHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [
        activity.title, activity.media == nil ? nil : activity.detail,
        Island.Activity.reading(activity.trailing, now: .now),
      ].compactMap { $0 }.joined(separator: "，")
    )
    .accessibilityActions {
      if let media = activity.media {
        Button(media.snapshot.isPlaying ? "暂停" : "播放") { media.send(.toggle) }
      }
    }
  }

  /// 正在播放：左耳封面（20 pt）、右耳跳动条（在播且速率 > 0 才动）。别的活动：记号和读数
  @ViewBuilder private var leading: some View {
    if let media = activity.media {
      // 暂停时封面暗一半（同 Alcove：一眼看得出停着）
      IslandMediaArt(media: media, size: 20)
        .opacity(media.snapshot.isPlaying ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: media.snapshot.isPlaying)
        .overlay { if reduceMotion { IslandSkipArrow(skip: skip, size: 20) } }
    } else {
      IslandActivityMark(activity: activity, size: 12)
    }
  }

  @ViewBuilder private var trailing: some View {
    if let media = activity.media {
      // 整块右耳是一个按钮：平时画跳动条（点了也是切换）；指针在岛上时换成播放 / 暂停的符号，告诉你点它不用展开。
      // 左耳和刘海照旧：点了展开卡片 / 开那一张
      Button {
        media.send(.toggle)
      } label: {
        ZStack {
          IslandBars(
            moving: media.snapshot.isPlaying && media.snapshot.rate > 0,
            color: media.tint ?? NSColor(activity.tint)
          )
          .opacity(peeking ? 0 : 1)
          Image(systemName: media.snapshot.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .scaleEffect(peeking ? 1 : 0.6)
            .opacity(peeking ? 1 : 0)
        }
        .frame(width: Island.wing, height: notchHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(IslandButtonStyle())
      .animation(Style.Motion.snap.animation(), value: peeking)
    } else if activity.ticks {
      // 只在耳朵露着时每秒推一次；Ticker 只换变了的那几位数字（图层动画，渲染服务做）
      TimelineView(.periodic(from: .now, by: 1)) { context in
        reading(Island.Activity.reading(activity.trailing, now: context.date) ?? "")
      }
    } else if let text = Island.Activity.reading(activity.trailing, now: .now) {
      reading(text)
    }
  }

  private func reading(_ text: String) -> some View {
    Ticker(
      text: text, font: Self.font(for: text), color: .white.withAlphaComponent(0.92),
      direction: Style.reduceMotion ? 0 : (activity.trailing.isCountdown ? -1 : 1))
  }

  /// 12 pt 等宽数字，放不下（「1:02:03」）就缩到 10
  static func font(for text: String) -> NSFont {
    .monospacedDigitSystemFont(ofSize: text.count > 5 ? 10 : 12, weight: .semibold)
  }
}

extension Island.Activity.Trailing {
  fileprivate var isCountdown: Bool {
    if case .countdown = self { true } else { false }
  }
}

/// 活动的记号（左耳、那一张里的一行）：有进度时一圈进度，不然是符号——带圆底的画成语气色圆底 + 白符号，裸符号染语气色
struct IslandActivityMark: View {
  let activity: Island.Activity
  /// 符号字号；一圈进度的直径 = 字号 + 2
  let size: CGFloat

  var body: some View {
    if case .fraction(let value) = activity.trailing {
      IslandRing(fraction: value, tint: activity.tint).frame(width: size + 2, height: size + 2)
    } else if Island.hasPlate(activity.symbol) {
      Image(symbol: activity.symbol)
        .font(.system(size: size, weight: .semibold))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, activity.tint)
    } else {
      Image(symbol: activity.symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(activity.tint)
    }
  }
}

/// 活动的读数用普通的字（卡片、那一张里：开着只有几秒，每秒换字不滚）；每秒在变的才挂 TimelineView
struct IslandActivityReading: View {
  let activity: Island.Activity

  var body: some View {
    if activity.ticks {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        text(Island.Activity.reading(activity.trailing, now: context.date))
      }
    } else {
      text(Island.Activity.reading(activity.trailing, now: .now))
    }
  }

  @ViewBuilder private func text(_ reading: String?) -> some View {
    if let reading {
      Text(reading)
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(1)
        .fixedSize()
    }
  }
}

/// 一圈进度（长任务的左耳、那一张里的一行）：底 white 0.18、填活动的颜色，0.2 s 线性跟着走
struct IslandRing: View {
  let fraction: Double
  let tint: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
      Circle().trim(from: 0, to: min(max(fraction, 0), 1))
        .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
    }
    .accessibilityHidden(true)
  }
}
