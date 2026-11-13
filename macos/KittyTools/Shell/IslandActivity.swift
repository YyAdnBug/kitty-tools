// 刘海岛的「活动」（2026-11-13，刘海岛扩展拍板 B1–B3、C1–C4，用户「按推荐开始」）：一直挂着的状态——录屏 / 录音中、
// 慢的长任务、一小时以内的提醒倒数、保持唤醒。和弹一下就走的提示是两回事。
// 刘海屏上收起时挂在刘海两侧的「耳朵」上（每侧 Island.wing = 36 pt：左边图标或一圈进度、右边计时 / 百分比），只露最要紧的
// 一个（B2：录制 > 长任务进度 > 保持唤醒 > 提醒倒数）；指针停上去鼓起一点，点耳朵展开成卡片（同悬停展开的样子，有停止、
// 暂停这类按钮），点刘海本身照旧是「那一张」，最上面多一行正在进行的活动（B3）。提示照旧从刘海长出来盖住耳朵，收起后
// 缩回耳朵、不缩进刘海。没有刘海屏的 Mac 上不挂耳朵（H1：放进菜单栏，第 1-3 批）。
// 这里是模型、先后和读数的纯函数，耳朵上那两小块的画法；状态和窗口在 Island.swift，形体在 IslandView。
// 每秒在变的读数用 Ticker（图层滚数字，不用 numericText：每秒换一次要 7–15% CPU），只在耳朵露着时由 TimelineView 每秒推一次。

import SwiftUI

extension Island {
  struct Activity: Identifiable {
    /// 哪一类（也是先后：数大的先露，拍板 B2）
    enum Kind: Int, Comparable {
      case reminder, awake, progress, record

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
    /// 卡片和那一张里的标题、读屏念的：「录屏中」「正在压缩」
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

    init(
      id: String, kind: Kind, title: String, detail: String? = nil, symbol: String,
      tone: Tone = .info, trailing: Trailing = .none, actions: [Action] = [],
      started: Date = .now
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
    }

    /// 耳朵上露哪一个（B2）：类别要紧的先；同一类后开始的先（刚开的那件事更可能是你在等的）
    static func top(_ activities: [Activity]) -> Activity? {
      activities.max { ($0.kind, $0.started) < ($1.kind, $1.started) }
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
}

/// 刘海两侧的耳朵：左边图标 / 一圈进度，中间让出刘海，右边读数。画在岛的黑底上（同 Island 的深色）
struct IslandWings: View {
  let activity: Island.Activity
  /// 刘海宽（Island.Geometry.notch 给的，真刘海 + 4）、高
  let notchWidth: CGFloat
  let notchHeight: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      leading.frame(width: Island.wing)
      Color.clear.frame(width: notchWidth)
      trailing.frame(width: Island.wing)
    }
    .frame(height: notchHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [activity.title, Island.Activity.reading(activity.trailing, now: .now)].compactMap { $0 }
        .joined(separator: "，"))
  }

  private var leading: some View {
    IslandActivityMark(activity: activity, size: 12)
  }

  @ViewBuilder private var trailing: some View {
    if activity.ticks {
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
