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
      /// event：十分钟内要开始的日程（2026-11-14）——比保持唤醒、提醒的倒数要紧（它们一挂几个小时，会议马上就到）；
      /// heldReminder：专注模式里到点、先压着没弹出的提醒（2026-11-17 拍板 B3）——比倒数、保持唤醒要紧（已经到点了）
      /// focus：开着的系统专注模式（2026-11-18，照 Alcove 一直挂着）——最不要紧：放歌、倒数、录制时都让给它们
      case focus, media, reminder, awake, heldReminder, event, progress, record

      static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 右耳上的读数
    enum Trailing: Equatable {
      /// 从这一刻起往上数（录制）
      case elapsed(since: Date)
      /// 倒数到这一刻（提醒、保持唤醒；耳朵上一小时以上写「4小时」，见 wingReading）
      case countdown(to: Date)
      /// 做到哪了 0…1（长任务）：右耳写百分比，左耳画一圈进度
      case fraction(Double)
      /// 定死的一小段字（暂停时的「0:42」）
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
    /// 从进行中的提示缩进来的：原来那一条的 Content.source（换回提示时还按它认，progress / dismiss(ifShowing:) 找得到）
    var source: LocalizedStringResource?
    /// 左耳画这个表情（StatusPreset.symbol 那种：表情 id 或自己挑的系统表情）、不画 symbol（提醒自己的图标，2026-11-17
    /// 拍板 C5）；卡片前导和菜单栏那一项照旧用 symbol
    var emoji: String?
    /// 右耳的读数一直用强调色（专注模式里挂着的提醒写几条，拍板 B3）；倒数最后 1 分钟不靠它也变色（isClosing）
    var tintsReading: Bool

    init(
      id: String, kind: Kind, title: String, detail: String? = nil, symbol: String,
      tone: Tone = .info, trailing: Trailing = .none, actions: [Action] = [],
      started: Date = .now, media: Media? = nil, onWings: Bool = true,
      source: LocalizedStringResource? = nil, emoji: String? = nil, tintsReading: Bool = false,
      color: NSColor? = nil
    ) {
      self.color = color
      self.emoji = emoji
      self.tintsReading = tintsReading
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
      self.source = source
    }

    /// 耳朵上露哪一个（B2）：上得了耳朵的里面，类别要紧的先；同一类后开始的先（刚开的那件事更可能是你在等的）
    static func top(_ activities: [Activity]) -> Activity? {
      activities.filter(\.onWings).max { ($0.kind, $0.started) < ($1.kind, $1.started) }
    }

    /// 读数（纯函数，单测锁住）：计时同录制 HUD（0:42、1:02:03），倒数到 0 停住，百分比取整。卡片、菜单栏那一项、读屏用它；
    /// 耳朵上用 wingReading（倒数只到分钟 / 小时）
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

    /// 耳朵上的字：倒数还剩一小时以上写「4小时」（往下取整，同钟表；不带空格，省地方）——「1:00:00」10 pt 也要 40 pt 宽，
    /// 耳朵只有 36（保持唤醒一开就是几个小时，2026-11-16 截图自检看出来的）；10 分钟以上只写分钟「42分」（往上取整，每分钟
    /// 才换一次、挂在眼角不滚，2026-11-17 拍板 C1），最后 10 分钟走秒。卡片、菜单栏那一项、读屏照旧是 reading 的精确倒数。
    /// 正计时（录屏超过一小时的「1:02:03」）不改：录着时要看秒在走
    static func wingReading(_ trailing: Trailing, now: Date) -> String? {
      if case .countdown(let end) = trailing {
        let seconds = Int(end.timeIntervalSince(now).rounded(.up))
        if seconds >= 3600 {
          return String(
            localized: "island.wingHours", defaultValue: "\(seconds / 3600)小时",
            comment: "刘海岛耳朵上一小时以上的倒数：4小时（耳朵只有 36 pt，不带空格；短说法）")
        }
        if seconds > tickingSpan {
          return String(
            localized: "island.wingMinutes", defaultValue: "\((seconds + 59) / 60)分",
            comment: "刘海岛耳朵上 10 分钟以上的倒数：42分（往上取整；耳朵只有 36 pt，不带空格；短说法）")
        }
      }
      return reading(trailing, now: now)
    }

    /// 耳朵上倒数最后这么多秒走秒
    static let tickingSpan = 10 * 60

    /// 倒数到了最后 1 分钟（还没到 0）：耳朵上的读数换成强调色（拍板 C4，不闪）
    static func isClosing(_ trailing: Trailing, now: Date) -> Bool {
      guard case .countdown(let end) = trailing else { return false }
      let left = end.timeIntervalSince(now)
      return left > 0 && left <= 60
    }

    /// 这一个的读数每秒在变（耳朵露着时要每秒推一次）
    var ticks: Bool {
      switch trailing {
      case .elapsed, .countdown: true
      default: false
      }
    }

    /// 自己的颜色（日程：它所在日历的颜色）；nil = 跟语气走
    var color: NSColor?

    var tint: Color { color.map { Color(nsColor: $0) } ?? IslandLeading.tint(tone) }

    /// 展开成卡片时的样子（前导同提示：语气色圆底的符号）
    var content: Content {
      var fraction: Double?
      if case .fraction(let value) = trailing { fraction = value }
      var content = Content(
        title: "\(title)", detail: detail.map { "\($0)" }, tone: tone, symbol: symbol,
        leading: .tone, fraction: fraction)
      if let source { content.source = source }
      content.tint = color
      return content
    }
  }

  /// 耳朵每侧多宽（拍板 B1：不超过 36 pt，免得盖住离刘海最近的菜单栏图标）
  static let wing: CGFloat = 36

  /// 音量 / 亮度提示在刘海每侧伸出多宽、比刘海高多少：每侧 90、**和刘海一样高**——只往两边长，不往下长（Alcove
  /// 不放歌、指针不在岛上时的实录：394 × 37.5；我们的「刘海宽」比真刘海宽几个点，每侧 90 量出来正好 394.5。原来定的
  /// 108、高出 5 是照它「指针停在岛上、鼓起着」的那段录像量的，量大了；用户装上后说往两边展开的动画不对）。放得下
  /// 符号 + 两个字、一根 68 pt 的细条。比耳朵宽，会盖住离刘海最近的菜单栏图标——只有两秒多
  nonisolated static let levelWing: CGFloat = 90
  static let levelDrop: CGFloat = 0

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
  /// 专注模式开着、设置里打开了「跳动条换成专注模式的图标」：正在播放的右耳画模式的符号（2026-11-17，照 Alcove）
  var focusMark: Island.FocusMark?
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
      ].compactMap { $0 }.joined(separator: Island.comma)
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
    } else if let emoji = activity.emoji {
      // 岛是深色（.colorScheme(.dark)）：要垫浅底的那两个表情按它垫（StatusEmoji.menuImage 看的是 AppKit 的外观，浅色模式下不垫）
      StatusPresetIcon(symbol: emoji, size: 15)
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
          Group {
            if let focusMark {
              Image(systemName: focusMark.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: focusMark.tint))
            } else {
              IslandBars(
                moving: media.snapshot.isPlaying && media.snapshot.rate > 0,
                color: media.tint ?? NSColor(activity.tint)
              )
            }
          }
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
        reading(
          Island.Activity.wingReading(activity.trailing, now: context.date) ?? "",
          tinted: Island.Activity.isClosing(activity.trailing, now: context.date))
      }
    } else if let text = Island.Activity.wingReading(activity.trailing, now: .now) {
      reading(text, tinted: false)
    } else {
      // 右耳没东西（专注模式那种只有图标的活动）也得占住 36：空着的话这一侧不占宽，整排居中后左耳的图标往里挪半个耳朵、
      // 被真刘海挡住（2026-11-18 用户装上后报的）
      Color.clear
    }
  }

  /// 白 85%；专注模式里挂着的提醒（tintsReading）、倒数最后 1 分钟用活动的颜色
  private func reading(_ text: String, tinted: Bool) -> some View {
    Ticker(
      text: text, font: Self.font(for: text),
      color: tinted || activity.tintsReading
        ? Self.onDark(NSColor(activity.tint)) : .white.withAlphaComponent(0.85),
      direction: Style.reduceMotion ? 0 : (activity.trailing.isCountdown ? -1 : 1))
  }

  /// 岛固定是深色：颜色按深色那一档取成定值（同 IslandBars）——App 是浅色时 cgColor 会取成浅色那一档；动态色换外观前后
  /// 比起来相等，Ticker 也不会重画
  static func onDark(_ color: NSColor) -> NSColor {
    var resolved = color.cgColor
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { resolved = color.cgColor }
    return NSColor(cgColor: resolved) ?? color
  }

  /// 11 pt 中粗的等宽数字（2026-11-17 拍板 C3：原来 12 pt 粗体，五个字把 36 pt 的耳朵塞满、比左耳的图标重），一只耳朵放不下
  /// （「1:02:03」「15小时」）就缩到 10。按排出来的宽度挑，不按字数：「15小时」只有 4 个字，却比「42:00」宽
  static func font(for text: String) -> NSFont {
    let regular = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    return TickerView.measure(text, font: regular).size.width <= Island.wing
      ? regular : .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
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
