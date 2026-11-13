// 刘海岛（Whisker 招牌时刻 S2，mac-whisker §5）：全局轻提示从刘海里长出来；没有刘海的屏幕上是菜单栏下方的黑色胶囊。
// 一个尺寸固定、平时不抢键盘的透明窗口（IslandPanel：只为「那一张」用快捷键叫出时能临时当 key，level 状态栏）放在鼠标所在屏顶部正中，
// 只让 SwiftUI 里的岛形状变形，不动画窗口 frame。内容晚 60 ms 出场；原地更新（翻译中 → 已替换）只换宽度；
// 错误时整座岛左右抖一下；消失时先退内容，再缩回刘海。停留：只有标题 1.4 s、带详情 2 s、错误 3 s、带按钮 6 s、进行中一直挂着。
// 能交互（2026-10-26 拍板，全部按推荐）：鼠标挪到岛上就停住计时、往下长成卡片（完整详情、全部按钮、×），离开 1.5 s 后收；
// 点岛本身执行「打开」类的按钮；双指往上滑收起；鼠标在岛上时来的新提示先排着。窗口平时不接鼠标，只在指针落在
// 画出来的形状上时才接（全局 + 本 App 的鼠标移动监听按位置开关），透明处和阴影那一圈照旧点穿。
// 主动叫出来（同日用户「不能手动交互吗」，三项按推荐）：没有提示时点刘海（指针停在刘海上岛先鼓起一点），或者按
// 「打开刘海岛」的快捷键（哪块屏都行），长出「那一张」：一排快捷动作 + 本次启动以来最近 10 条提示（IslandBoard.swift；
// 快捷动作开哪几个、什么先后，列不列提示，在 设置 › 刘海岛，2026-11-12 PR #17）。
// 用快捷键叫出的那一张临时当 key（第四轮体检 U9）：Esc 收、←→ 选快捷动作、↩ 执行，到点自己收（同平时的岛）；收起时键盘
// 还给原来那扇窗口 / 原来的 App。点刘海叫出的照旧不抢键盘。
// 活动（2026-11-13，刘海岛扩展 B1–B3，IslandActivity.swift）：一直挂着的状态（录制中、长任务……）在刘海屏上收起时挂在
// 刘海两侧的耳朵上；指针停上去鼓起一点，点耳朵展开成卡片，点刘海照旧是那一张（最上面列着活动）。提示收起后缩回耳朵。
// 挂着直到处理（pin，2026-11-04 提醒 C2）：到点的提醒不到点收起，中间来的别的提示先显示、收起后换回它；只有它的按钮、×、
// 双指上滑收得掉（×、上滑告诉调用方「处理了」）。一次只挂一条（几条提醒由调用方合成一条）。

import AppKit
import OSLog
import Observation
import SwiftUI

@Observable final class Island {
  enum Tone {
    case success, info, warning, error
    /// 进行中：一直挂着，直到下一条替换它（60 s 兜底）
    case progress
  }

  /// 前导位置：按语气出符号（一律是语气色的圆底 + 上面的符号，见 hasPlate），或者取色的色块、截图的缩略图
  enum Leading: Equatable {
    case tone
    case color(NSColor)
    case thumbnail(NSImage)
  }

  struct Content: Equatable {
    var title: String
    var detail: String?
    var tone: Tone
    var symbol: String
    var leading: Leading
    /// 进行中、且知道做到哪了（0…1：更新包下载、转 GIF、压缩）：标题后面多一条细进度条。nil = 不画
    var fraction: Double?
  }

  /// 岛上的一个按钮。第一个是最主要的：平时露在行尾，展开后在 × 左边（拍板 B2）
  struct Action {
    let title: String
    /// 打开类（在访达中显示、打开系统设置里那一项、跳到设置的某一页）：点岛本身也执行它（拍板 B3）。
    /// 撤销、取消、重试、继续这类是 false，只能点按钮
    var opens = false
    /// 那一张上的快捷动作画成符号 + 小字（提示上的按钮不用）
    var symbol: String?
    let run: () -> Void

    init(
      _ title: String, opens: Bool = false, symbol: String? = nil, run: @escaping () -> Void
    ) {
      self.title = title
      self.opens = opens
      self.symbol = symbol
      self.run = run
    }
  }

  /// 记下来的一条提示（那一张里的一行）
  struct Record: Identifiable {
    let id = UUID()
    let content: Content
    /// 只留打开类的按钮：撤销、取消、重试这类过后再点会出事
    let actions: [Action]
    let at: Date
  }

  /// 正在显示的内容；nil = 内容已退场（形体可能还在缩回）
  private(set) var content: Content?
  /// 形体展开着
  private(set) var isOpen = false
  /// 每次出错 +1，触发抖动
  private(set) var shakes = 0
  /// 这一条的按钮；内容换了就跟着换
  private(set) var actions: [Action] = []
  /// 鼠标停在岛上（指针动过、落在形状里才算，拍板 B6）
  private(set) var isHovered = false
  /// 长成了卡片：悬停时展开；离开后照旧开着直到收起（进行中的离开就合上，它还要挂着）
  private(set) var isExpanded = false
  /// 「那一张」开着：点刘海、快捷键「打开刘海岛」叫出来的（快捷动作 + 最近的提示，IslandBoard）
  private(set) var isBoardOpen = false
  /// 没有提示、没开那一张时指针停在刘海上：岛轻轻鼓起一点，告诉你能点
  private(set) var isPeeking = false
  /// 最近的提示：本次启动以来最近 historyLimit 条，新的在前；进行中的不记
  private(set) var history: [Record] = []
  /// 那一张上的快捷动作：打开时从 boardActions 取一次
  private(set) var quickActions: [Action] = []
  /// 那一张上列不列最近的提示（设置 › 刘海岛，Prefs.islandShowsHistory）：打开时读一次。不列也照样记着
  private(set) var showsHistory = true
  /// 一直挂着的活动（IslandActivity.swift）；耳朵上露最要紧的一个（activity）
  private(set) var activities: [Activity] = []
  /// 耳朵该露着：有活动、有刘海屏。提示、那一张开着时照旧是它们，收起后缩回耳朵（不缩进刘海、窗口不移走）
  private(set) var isShowingWings = false
  /// 展开着的卡片是哪个活动的（点耳朵展开的）：它更新时卡片原地换，结束时收起；卡片上标题旁边挂它的实时读数
  private(set) var expandedActivity: String?
  /// 没有刘海屏时活动挂在菜单栏里（刘海岛扩展 H1，IslandMenuItem）
  @ObservationIgnored private lazy var menuItem: IslandMenuItem = {
    let item = IslandMenuItem()
    item.onClick = { [weak self] in self?.expand($0) }
    return item
  }()
  /// 点刘海、停在刘海上、两指往下滑叫出那一张（设置 › 刘海岛「点刘海叫出那一张」，刘海岛扩展 G2；AppDelegate 跟着偏好给）。
  /// 关着时这几样都不响应，快捷键照样能叫出来；耳朵上的活动照常能停、能点
  @ObservationIgnored var respondsToNotch = true
  /// 刘海岛插件添加着（Feature.island，2026-11-13 插件化 P1b；AppDelegate 跟着开关给）：点刘海那一张、活动（耳朵、菜单栏那一项、
  /// 进行中缩进耳朵）、刘海上常驻的鼠标监听都归它。没添加时只弹提示（0.7.0 之前的样子）：setActivity 不收、进行中照旧挂着、
  /// 不常驻监听（点刘海另由 respondsToNotch 关掉，快捷键「打开刘海岛」随插件不注册）。摆出来的岛（截图自检、单测）是 true
  @ObservationIgnored var hasExtras = true {
    didSet {
      guard hasExtras != oldValue else { return }
      if !hasExtras {
        let progressing = activities.last { $0.kind == .progress }
        for activity in activities { endActivity(activity.id) }
        if isBoardOpen { dismiss() }
        // 缩进耳朵的进行中换回挂着的提示：不然之后的进度、「停止」都没处放，一直到结果出来都看不见（评审 4）
        if let progressing {
          var content = progressing.content
          content.tone = .progress
          apply(content, actions: progressing.actions)
        }
      }
      rewatchNotch()
    }
  }
  /// 用快捷键叫出的那一张上，←→ 选中的快捷动作（第几个；鼠标叫出的、没有快捷动作时是 nil，U9）
  private(set) var boardSelection: Int?
  /// 那一张是用快捷键叫出的、正临时拿着键盘：收起时还回去
  @ObservationIgnored private var holdsKeyboard = false
  /// 叫出那一张之前本 App 里当 key 的窗口（固定着的剪贴板面板、设置窗）：还键盘时还给它
  @ObservationIgnored private weak var keyBeforeBoard: NSWindow?
  /// 快捷动作从哪来（AppDelegate 给：截图、录屏、录音、识字、截图翻译、快速记一条，照设置里的先后；关掉的、关着的功能不给）
  @ObservationIgnored var boardActions: () -> [Action] = { [] }
  /// 各块屏上硬件刘海的位置（屏幕坐标）：屏幕变了就重算
  @ObservationIgnored private var notchRects: [CGRect] = []
  /// start() 过、而且有刘海屏：监听一直装着（点刘海、停在刘海上要它们），收起后不卸。没有刘海的 Mac 照旧显示时装、收起后卸
  @ObservationIgnored private var watchesNotch = false
  /// 收起后形体还在缩回（retract 动画那 0.34 s）：这时不鼓，免得把还在缩的窗口改回小的、截掉一截
  @ObservationIgnored private var isRetracting = false
  /// 这会儿不响应刘海（AppDelegate 给：截图 / 录屏框选中、启动台开着、状态屏里）：点它、停在它上面都不算
  @ObservationIgnored var isSuppressed: () -> Bool = { false }
  @ObservationIgnored private var screenObserver: Any?
  @ObservationIgnored private(set) var geometry = Geometry.capsule(menuBar: 24)
  @ObservationIgnored private var window: IslandPanel?
  @ObservationIgnored private var host: IslandHost?
  @ObservationIgnored private var dwell: Task<Void, Never>?
  /// 这一条到点收起的时刻；悬停时停住，离开后接着走剩下的（至少 leaveDelay）
  @ObservationIgnored private var deadline = ContinuousClock.now
  @ObservationIgnored private var remaining = Duration.zero
  /// 内容换过 / 刚展开的时刻：之后 clickGuard 以内的点击不算（拍板 B6，按钮会挪位置）
  @ObservationIgnored private var changedAt: ContinuousClock.Instant?
  /// 鼠标在岛上时来的新提示：移开再换上，只留最新一条（拍板 B5）
  @ObservationIgnored private var pending: (content: Content, actions: [Action])?
  /// 挂着直到处理的那一条（提醒，PLAN §10「提醒」C2；pin）：不到点收起，别的提示来了先显示那条、收起后换回它
  @ObservationIgnored private var pinned:
    (content: Content, actions: [Action], onClose: () -> Void)?
  @ObservationIgnored private var monitors: [Any] = []
  /// 悬停期间每 0.2 s 再核一次指针：从岛直接挪进本 App 不收鼠标移动的窗口时没有移动事件，靠它发现离开
  @ObservationIgnored private var hoverCheck: Task<Void, Never>?
  /// 形状在窗口里的位置（IslandView 量了报上来，左上角原点）：判断指针在不在岛上
  @ObservationIgnored var shapeFrame = CGRect.zero
  /// 语气变了（nil = 收起）：菜单栏图标据此呼吸 / 弹一下（StatusItem.reflect）
  @ObservationIgnored var onToneChange: ((Tone?) -> Void)?

  /// 刘海屏：从刘海长出下巴；其它屏：菜单栏下方的胶囊
  enum Geometry: Equatable {
    case notch(width: CGFloat, height: CGFloat)
    case capsule(menuBar: CGFloat)

    /// 窗口尺寸：一次定死成最大的那个（那一张，boardHeight）+ 两侧耳朵与阴影余量——开那一张不改窗口大小，
    /// 改大小会卡一下（窗口服务器的 frame 变化和图层动画不在一个事务里）。开过一次那一张和一直这么高，常驻内存一样
    var windowSize: CGSize {
      switch self {
      case .notch(_, let notch):
        CGSize(width: Island.canvasWidth, height: notch + Island.boardHeight + 26)
      case .capsule: CGSize(width: Island.canvasWidth, height: Island.boardHeight + 34)
      }
    }
  }

  /// 摆出来的岛（截图自检、单测）：从头到尾不建窗口——收起后再 show 也不会弹到屏幕上
  @ObservationIgnored private let isStaged: Bool

  init() { isStaged = false }

  /// 截图自检、单测直接摆出某一刻的样子；正常使用就是 `Island()`
  /// board：摆出开着的那一张（里面这几条提示）；peeking：摆出指针停在刘海上鼓起的样子
  init(
    showing content: Content?, geometry: Geometry = .capsule(menuBar: 24),
    actions: [Action] = [], expanded: Bool = false, board records: [Record]? = nil,
    quickActions: [Action] = [], peeking: Bool = false, boardSelection: Int? = nil,
    showsHistory: Bool = true, activities: [Activity] = []
  ) {
    isStaged = true
    self.content = content
    isOpen = content != nil || records != nil
    self.geometry = geometry
    self.actions = actions
    isExpanded = expanded
    isBoardOpen = records != nil
    history = records ?? []
    self.quickActions = quickActions
    isPeeking = peeking
    self.boardSelection = boardSelection
    self.showsHistory = showsHistory
    self.activities = activities
    // 同真的岛（refreshWings）：有上得了耳朵的活动才露（暂停一阵的正在播放不上）
    if case .notch = geometry { isShowingWings = Activity.top(activities) != nil }
  }

  /// 详情里的一句摘录：第一行前 24 个字，后面还有就补「…」（\r\n、\r、U+2028 都算换行）
  static func excerpt(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let head = trimmed.prefix { !$0.isNewline }.prefix(24)
    return head + (head.count < trimmed.count ? "…" : "")
  }

  /// 前导位置的截图缩略图：同飞行卡片取顶部一段，缩到 26×18 的两倍像素。
  /// 不把整张原图放进岛（长截图可到 4000 万像素，岛要挂 1.4–2 s）
  static func thumbnail(of image: CGImage) -> Leading {
    let top = FlyCard.visiblePart(of: image, frame: CGRect(x: 0, y: 0, width: 26, height: 18))
    return .thumbnail(
      NSImage(
        cgImage: FlyCard.thumbnail(of: top, fitting: CGSize(width: 52, height: 36)), size: .zero))
  }

  /// 下巴 / 胶囊高度
  static let chin: CGFloat = 36
  static let maxWidth: CGFloat = 460
  /// 画布（窗口）宽：最宽 460 的岛 + 两侧耳朵与阴影余量
  static let canvasWidth: CGFloat = 520
  /// 离开岛后至少再留多久
  static let leaveDelay = Duration.milliseconds(1500)
  static let clickGuard = Duration.milliseconds(300)
  /// 那一张多宽、最高多少（一排快捷动作 + historyLimit 行提示）
  static let boardWidth: CGFloat = 420
  static let boardHeight: CGFloat = 440
  static let historyLimit = 10
  /// 指针停在刘海上时岛比刘海宽出、长出多少（每侧 8、往下 5）；停在这一圈里也算停在刘海上
  static let peekGrow = CGSize(width: 8, height: 5)

  func show(
    _ title: String, detail: String? = nil, tone: Tone = .success, symbol: String? = nil,
    leading: Leading = .tone, fraction: Double? = nil, actions: [Action] = []
  ) {
    let next = Content(
      title: title, detail: detail, tone: tone, symbol: symbol ?? Self.symbol(for: tone),
      leading: leading, fraction: fraction)
    // 不是进行中的 = 结果来了：缩进耳朵的进行中跟着收（同原来「进行中挂着，直到下一条替换它」）
    // ponytail: 分不出这一条是不是它的结果，中途来一条不相干的提示也会把它收掉（和原来一样）；要分就给进行中配一个编号
    if tone != .progress {
      endProgress()
      remember(next, actions: actions)
    }
    // 鼠标正停在岛上：先排着，免得正要点的按钮被换掉（B5）。进行中的那条例外——来的是它的结果，原地换。
    // 那一张开着时也排着（收起后再出；那一张里的列表当场就有它）
    let busy = isHovered && content.map { $0.tone != .progress } == true
    if isBoardOpen || busy {
      pending = (next, actions)
      return
    }
    apply(next, actions: actions)
  }

  /// 记进最近的提示（那一张里列），按钮只留打开类的
  private func remember(_ content: Content, actions: [Action]) {
    history.insert(Record(content: content, actions: actions.filter(\.opens), at: .now), at: 0)
    // 鼠标正在那一张上：列表整体往下挪了一行，这一下的点击不算（同 B6）
    if isBoardOpen, isHovered { changedAt = .now }
    if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
  }

  /// quiet：展开活动的卡片（不是新提示）——菜单栏图标不跟着呼吸 / 弹一下
  private func apply(_ next: Content, actions: [Action], quiet: Bool = false) {
    // 那一张开着时换成这一条：键盘还回去
    releaseKeyboard()
    if !quiet { expandedActivity = nil }
    self.actions = actions
    // 离开后照旧展开着的那张卡片：换成新的一条就合上，新提示一律从一行出来
    if !isHovered, isExpanded { withAnimation(Self.resize) { isExpanded = false } }
    dwell?.cancel()
    changedAt = .now
    if isOpen, content != nil || isBoardOpen {
      // 原地更新：内容交叉模糊替换，宽度跟着内容走（spring 0.32）；那一张开着时换成这一条
      withAnimation(Self.resize) {
        isBoardOpen = false
        content = next
      }
    } else {
      open(with: next)
    }
    if next.tone == .error, !quiet { shakes += 1 }
    if next.tone == .progress { collapseLater(next.title) }
    if !quiet { onToneChange?(next.tone) }
    // VoiceOver 不会去读不当 key 的岛：主动播报
    Self.announce([next.title, next.detail].compactMap { $0 }.joined(separator: "，"))
    // 挂着的那条不到点收起（按钮、×、上滑才收）
    if let pinned, next == pinned.content {
      dwell?.cancel()
      return
    }
    // 带按钮的岛多留一会儿：1.4–2 秒来不及挪鼠标去点（G23）
    let seconds: Double =
      switch next.tone {
      case .progress: 60
      case .error: actions.isEmpty ? 3 : 6
      default: actions.isEmpty ? (next.detail == nil ? 1.4 : 2) : 6
      }
    if isHovered {
      remaining = .seconds(seconds)
    } else {
      arm(.seconds(seconds))
    }
  }

  /// 到点收起
  private func arm(_ delay: Duration) {
    dwell?.cancel()
    deadline = .now + delay
    dwell = Task { [weak self] in
      try? await Task.sleep(for: delay)
      if !Task.isCancelled { self?.dismiss() }
    }
  }

  /// 岛的宽度跟着内容变时用的曲线
  private static var resize: Animation {
    Style.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.15)
  }

  /// 进行中的岛改详情（更新包下载、转 GIF、压缩的百分比；fraction 是同一个进度，细进度条跟着走）：内容不重新出场、不播报
  /// （一秒几次，旁白会被刷屏），停留重新计时——事情还在做就一直挂着。岛上已经不是这一条（标题对不上、被别的岛换掉了）就不动
  func progress(_ title: String, detail: String, fraction: Double? = nil) {
    // 已经缩进耳朵的：改活动（卡片展开着就原地换），兜底的 60 s 重新计时
    if var activity = activities.first(where: { $0.id == Self.progressID(title) }) {
      activity.detail = detail
      if let fraction { activity.trailing = .fraction(fraction) }
      setActivity(activity)
      expireProgressLater()
      return
    }
    // 排着还没换上的那条：改它，换上来时就是最新的百分比
    if var queued = pending, queued.content.title == title, queued.content.tone == .progress {
      queued.content.detail = detail
      queued.content.fraction = fraction
      pending = queued
      return
    }
    guard isOpen, let content, content.title == title, content.tone == .progress,
      content.detail != detail || content.fraction != fraction
    else { return }
    // 细条刚出现 / 收掉时宽度变一大截，同原地更新的弹簧；平时只是数字在变，不动画
    withAnimation((content.fraction == nil) != (fraction == nil) ? Self.resize : nil) {
      self.content?.detail = detail
      self.content?.fraction = fraction
    }
    if isHovered { remaining = .seconds(60) } else { arm(.seconds(60)) }
  }

  /// 慢活的「进行中」岛：work 超过 delay 还没做完才出（很快做完的不闪这一下）。做完之后调用方出结果岛就原地换掉它；
  /// 没有结果岛的调用方自己收（dismiss(ifShowing:)）
  func showIfSlow<T>(
    _ title: String, symbol: String? = nil, after delay: Duration = .milliseconds(300),
    _ work: () async -> T
  ) async -> T {
    await Self.whenSlow(
      after: delay, notice: { [weak self] in self?.show(title, tone: .progress, symbol: symbol) },
      work: work)
  }

  /// work 超过 delay 还没做完才调 notice（单测不建岛的窗口，直接测这个）
  static func whenSlow<T>(
    after delay: Duration, notice: @escaping () -> Void, work: () async -> T
  ) async -> T {
    let pending = Task {
      try? await Task.sleep(for: delay)
      if !Task.isCancelled { notice() }
    }
    defer { pending.cancel() }
    return await work()
  }

  /// 指针进出岛：进来停住计时、展开、窗口接鼠标；出去接着走剩下的时间（至少 1.5 s），排着的那条这时换上
  func hover(_ inside: Bool) {
    guard inside != isHovered else { return }
    isHovered = inside
    window?.ignoresMouseEvents = !inside
    if inside {
      dwell?.cancel()
      remaining = max(deadline - .now, .zero)
      if !isExpanded, !isBoardOpen {
        changedAt = .now
        withAnimation(Style.Motion.island.animation()) { isExpanded = true }
      }
      hoverCheck?.cancel()
      hoverCheck = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(200))
          guard let self, !Task.isCancelled else { return }
          self.track()
        }
      }
      return
    }
    hoverCheck?.cancel()
    // 那一张开着时不当场换：离开 1.5 s 到点收起，dismiss 自己会换上排着的那条
    if !isBoardOpen, let (next, actions) = pending {
      pending = nil
      apply(next, actions: actions)
      return
    }
    if content?.tone == .progress || isShowingPinned {
      withAnimation(Style.Motion.retract.animation()) { isExpanded = false }
    }
    arm(max(remaining, Self.leaveDelay))
  }

  /// 岛上现在就是挂着的那一条
  private var isShowingPinned: Bool { pinned != nil && content == pinned?.content }

  /// 内容刚换过 / 刚展开（按钮挪了位置）的那一下不算点击
  private var isSettled: Bool {
    guard let changedAt else { return true }
    return ContinuousClock.now - changedAt >= Self.clickGuard
  }

  /// 点岛上的按钮：先收起再跑（跑之前岛已经不在，动作里弹面板不会和岛抢）。排着的那条让给按钮自己的结果：
  /// 按钮没出新提示就换上它，出了就等那条收起再出。checked = false：键盘按的 ↩（不怕「按钮刚挪了位置」那一下）
  func perform(_ action: Action, checked: Bool = true) {
    guard !checked || isSettled else { return }
    // 点的是挂着那条的按钮：它就处理完了（按钮自己告诉调用方），不再换回来
    if isShowingPinned { pinned = nil }
    let queued = pending
    pending = nil
    dismiss()
    action.run()
    guard let queued else { return }
    if content == nil { apply(queued.content, actions: queued.actions) } else { pending = queued }
  }

  /// 点 ×：挂着的那条就此处理完（告诉调用方，onClose）
  func close() {
    guard isSettled else { return }
    guard isShowingPinned, let closing = pinned else { return dismiss() }
    pinned = nil
    dismiss()
    closing.onClose()
  }

  /// 双指在岛上往上滑：同 ×（挂着的那条也算处理了），只是不等「刚换过」那 0.3 s
  func swipeAway() {
    guard isShowingPinned, let closing = pinned else { return dismiss() }
    pinned = nil
    dismiss()
    closing.onClose()
  }

  /// 双指在刘海上往下滑（刘海岛扩展 G1，同点刘海）：没开着东西时打开那一张。指针停在刘海上岛鼓起、窗口接鼠标时才收得到
  func swipeDown() {
    guard respondsToNotch, content == nil, !isBoardOpen, !isSuppressed() else { return }
    toggleBoard()
  }

  /// 挂在岛上直到处理（提醒，PLAN §10「提醒」C2）：不到点收起；中间来了别的提示先显示那条，它收起后换回这一条；
  /// 点它的按钮、点 ×、双指上滑才真的收（×、上滑调 onClose，按钮跑自己的动作）。再 pin 一次 = 换内容（几条提醒合成
  /// 一条，B5），内容一样只换按钮。鼠标正停在别的提示上、那一张开着时先挂着不出，那条收起 / 那一张关掉时换上
  func pin(
    _ title: String, detail: String?, symbol: String, actions: [Action],
    onClose: @escaping () -> Void
  ) {
    let next = Content(
      title: title, detail: detail, tone: .info, symbol: symbol, leading: .tone, fraction: nil)
    let wasShowing = isShowingPinned
    let same = pinned?.content == next
    pinned = (next, actions, onClose)
    if same {
      if wasShowing { self.actions = actions }
      return
    }
    remember(next, actions: actions)
    if isBoardOpen || (isHovered && content != nil && !wasShowing) { return }
    apply(next, actions: actions)
  }

  /// 催一下挂着的那条（提醒 C10）：整座岛左右抖一下（同出错时）、再播报一遍；没显示着它就不动
  func nudge() {
    guard isShowingPinned, let content else { return }
    shakes += 1
    Self.announce([content.title, content.detail].compactMap { $0 }.joined(separator: "，"))
  }

  /// 不再挂着（调用方那边处理完了、功能关了）：正显示着就收
  func unpin() {
    guard pinned != nil else { return }
    let showing = isShowingPinned
    pinned = nil
    if showing { dismiss() }
  }

  /// 收起标题是 title 的这一条（没有结果岛的进行中提示，调用方做完了自己收）：正显示着就收，排着就丢掉
  func dismiss(ifShowing title: String) {
    endActivity(Self.progressID(title))
    if pending?.content.title == title { pending = nil }
    if content?.title == title { dismiss() }
  }

  /// 点岛本身：耳朵露着、没别的东西时 = 展开最要紧的那个活动；有打开类的按钮就执行它，没有就什么都不做（点得到时已经展开着）。
  /// 点在刘海本身上的那一下由鼠标监听当成开那一张（click），到不了这里
  func tapped() {
    if content == nil, !isBoardOpen, isShowingWings { return expandActivity() }
    if let open = actions.first(where: \.opens) { perform(open) }
  }

  // MARK: 活动

  /// 耳朵上露的那一个（拍板 B2）
  var activity: Activity? { Activity.top(activities) }

  /// 卡片展开着的那个活动
  var cardActivity: Activity? { activities.first { $0.id == expandedActivity } }

  /// 开始 / 更新一个活动（同一个 id 再来一次 = 原地换，开始的时刻不变）。刘海屏上收起时挂到耳朵上；
  /// 它的卡片正展开着就原地换内容和按钮
  func setActivity(_ activity: Activity) {
    guard hasExtras else { return }
    var next = activity
    if let index = activities.firstIndex(where: { $0.id == activity.id }) {
      next.started = activities[index].started
      activities[index] = next
    } else {
      activities.append(next)
    }
    if expandedActivity == next.id, content != nil {
      content = next.content
      actions = next.actions
    }
    refreshWings()
  }

  /// 活动结束：它的卡片正展开着就收起；没有活动了耳朵缩回刘海
  func endActivity(_ id: String) {
    guard activities.contains(where: { $0.id == id }) else { return }
    activities.removeAll { $0.id == id }
    if expandedActivity == id {
      expandedActivity = nil
      if content != nil { dismiss() }
    }
    refreshWings()
  }

  /// 点耳朵：最要紧的那个活动展开成卡片（同悬停展开的样子），收起后回到耳朵
  private func expandActivity() {
    if let activity { expand(activity.id) }
  }

  /// 某个活动展开成卡片（耳朵、菜单栏那一项都走这里）
  private func expand(_ id: String) {
    guard let activity = activities.first(where: { $0.id == id }) else { return }
    isPeeking = false
    apply(activity.content, actions: activity.actions, quiet: true)
    expandedActivity = activity.id
    withAnimation(Self.resize) { isExpanded = true }
  }

  /// 耳朵该不该露：有活动、有刘海屏（摆出来的岛看给的几何）。没开着别的时当场长出 / 缩回；开着提示、那一张时只改标记，
  /// 它们收起时（dismiss）照这个缩回耳朵
  private func refreshWings() {
    let wanted = activity != nil && canShowWings
    if !isStaged { menuItem.show(IslandMenuItem.pick(activities, wings: canShowWings)) }
    guard wanted != isShowingWings else { return }
    if wanted, !isOpen, !isStaged { showWindow(on: Self.notchScreen) }
    withAnimation((wanted ? Style.Motion.island : Style.Motion.retract).animation()) {
      isShowingWings = wanted
    }
    guard !wanted, !isOpen, !isStaged else { return }
    Task { [weak self] in
      try? await Task.sleep(for: Self.retractTime)
      guard let self, !self.isOpen, !self.isPeeking, !self.isShowingWings else { return }
      self.window?.orderOut(nil)
    }
  }

  /// 有刘海的那块屏（耳朵挂在它上面）；没有是 nil
  private static var notchScreen: NSScreen? {
    NSScreen.screens.first { notchRect(of: $0) != nil }
  }

  /// 挂得了耳朵：有刘海屏（摆出来的岛看给的几何）
  private var canShowWings: Bool {
    if isStaged {
      if case .notch = geometry { true } else { false }
    } else {
      Self.notchScreen != nil
    }
  }

  // MARK: 慢的长任务缩进耳朵（刘海岛扩展 C4）

  /// 进行中的提示挂满这么久还没做完，缩回耳朵
  static let progressCollapse = Duration.seconds(3)
  /// 缩进耳朵的进行中多久没有新进度就收掉（同原来进行中提示的 60 s 兜底）
  static let progressExpiry = Duration.seconds(60)
  @ObservationIgnored private var collapseTask: Task<Void, Never>?
  @ObservationIgnored private var expiryTask: Task<Void, Never>?

  static func progressID(_ title: String) -> String { "progress:" + title }

  /// 进行中的提示出来了：挂满 3 秒还是它（指针不在上面）就缩进耳朵；指针在上面就等它离开
  private func collapseLater(_ title: String) {
    collapseTask?.cancel()
    guard hasExtras else { return }
    collapseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.progressCollapse)
      while !Task.isCancelled {
        guard let self, let content = self.content, content.tone == .progress,
          content.title == title
        else { return }
        if !self.isHovered, !self.isBoardOpen { return self.collapseProgress(content) }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// 把正显示着的进行中提示换成耳朵上的活动（左一圈进度、右百分比；说不出做到哪的只有记号），按钮（停止）跟过去，
  /// 提示收起、缩回耳朵。没有刘海屏时照旧挂着（菜单栏那一项是第 1-3 批）
  func collapseProgress(_ content: Content) {
    guard hasExtras, canShowWings, self.content == content else { return }
    setActivity(
      Activity(
        id: Self.progressID(content.title), kind: .progress, title: content.title,
        detail: content.detail, symbol: content.symbol,
        trailing: content.fraction.map { .fraction($0) } ?? .none, actions: actions))
    expireProgressLater()
    dismiss()
  }

  /// 缩进耳朵的进行中都收掉（结果来了）
  private func endProgress() {
    for activity in activities where activity.kind == .progress { endActivity(activity.id) }
    expiryTask?.cancel()
  }

  private func expireProgressLater() {
    expiryTask?.cancel()
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: Self.progressExpiry)
      if !Task.isCancelled { self?.endProgress() }
    }
  }

  /// 收起：内容先退（0.12 s），0.08 s 后形体缩回刘海，动画结束再移走窗口。鼠标在岛上时排着一条的（点了 ×、按钮，
  /// 或者调用方自己收），直接换成排着的那条
  func dismiss() {
    dwell?.cancel()
    releaseKeyboard()
    guard isOpen else { return }
    if let (next, actions) = pending {
      pending = nil
      apply(next, actions: actions)
      return
    }
    // 有挂着的那条：别的提示收起、那一张关掉时换回它；它自己只有按钮、×、上滑收得掉（unpin 先清掉再来）
    if let pinned {
      if !isShowingPinned { apply(pinned.content, actions: pinned.actions) }
      return
    }
    hoverCheck?.cancel()
    actions = []
    expandedActivity = nil
    isHovered = false
    isExpanded = false
    window?.ignoresMouseEvents = true
    onToneChange?(nil)
    // 内容先退（0.12 s），0.08 s 后形体缩回刘海（Whisker S2 的两拍；用户 2026-10-26 改成同时走后觉得没原来好看，
    // 改回来——那次的卡顿其实是收起终点露在刘海外面，已经由 IslandGeometry.tucked 解决）
    withAnimation(.easeIn(duration: 0.12)) {
      content = nil
      isBoardOpen = false
    }
    dwell = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard let self, !Task.isCancelled else { return }
      self.isRetracting = true
      withAnimation(Style.Motion.retract.animation()) { self.isOpen = false }
      try? await Task.sleep(for: Self.retractTime)
      guard !Task.isCancelled else { return }
      self.isRetracting = false
      guard !self.isOpen, !self.isPeeking else { return }
      // 有活动：缩回耳朵、窗口留着；提示是在别的屏（外接屏的胶囊）上弹的，就挪回刘海屏
      if self.isShowingWings {
        if case .notch = self.geometry { return }
        self.window?.orderOut(nil)
        self.showWindow(on: Self.notchScreen)
        return
      }
      self.window?.orderOut(nil)
      if !self.watchesNotch { self.unwatchMouse() }
    }
  }

  /// 缩回动画走完的时间（retract 0.34 s + 余量）：之后才移走窗口
  /// （缩回的弹簧标的 0.34 s 是感知上的时长，真停稳还要一会儿；终点藏在刘海后面，多留一会儿看不出来）
  private static let retractTime = Duration.milliseconds(600)

  /// 打开 / 收起那一张（快捷键「打开刘海岛」、点刘海）。岛上正有提示时换成那一张（那条已经记在列表里）。
  /// byKeyboard：快捷键叫出的——临时当 key，Esc / ←→ / ↩ 能用，到点自己收（U9）
  func toggleBoard(byKeyboard: Bool = false) {
    if isBoardOpen { dismiss() } else { openBoard(byKeyboard: byKeyboard) }
  }

  private func openBoard(byKeyboard: Bool = false) {
    dwell?.cancel()
    hoverCheck?.cancel()
    // 进行中的提示留着（排着，progress() 接着改它的百分比），收起那一张时换回来；别的已经在列表里了
    if let content, content.tone == .progress {
      pending = (content, actions)
    } else if pending?.content.tone != .progress {
      pending = nil
      onToneChange?(nil)
    }
    actions = []
    isHovered = false
    isExpanded = false
    isPeeking = false
    isRetracting = false
    quickActions = boardActions()
    showsHistory = UserDefaults.standard.object(forKey: Prefs.islandShowsHistory) as? Bool ?? true
    changedAt = .now
    deadline = .now
    showWindow()
    withAnimation(isOpen ? Self.resize : Style.Motion.island.animation()) {
      isOpen = true
      content = nil
      isBoardOpen = true
    }
    let heading =
      !showsHistory ? "快捷动作" : quickActions.isEmpty ? "最近的提示" : "最近的提示和快捷动作"
    guard byKeyboard, let window else { return Self.announce(heading) }
    takeKeyboard(window)
    Self.announce(
      quickActions.isEmpty
        ? "\(heading)，按 Esc 关闭"
        : "\(heading)，左右键选快捷动作，回车执行，Esc 关闭；现在是「\(quickActions[0].title)」")
  }

  /// 那一张没人碰时多久自己收（同带按钮的岛）
  static let boardKeyboardDwell = Duration.seconds(6)

  /// 快捷键叫出的那一张：临时当 key（窗口是不激活本 App 的面板，前台 App 不变），选中第一个快捷动作，到点自己收
  private func takeKeyboard(_ window: IslandPanel) {
    if let key = NSApp.keyWindow, key !== window { keyBeforeBoard = key }
    holdsKeyboard = true
    boardSelection = quickActions.isEmpty ? nil : 0
    window.keyable = true
    window.onKey = { [weak self] in self?.boardKey($0) }
    window.makeKey()
    arm(Self.boardKeyboardDwell)
  }

  /// 那一张上的按键（窗口当 key 时 sendEvent 交过来）：Esc 收、←→ 选（到头回绕）、↩ 执行；别的键吞掉、不响
  private func boardKey(_ event: NSEvent) {
    guard isBoardOpen, holdsKeyboard else { return }
    // 按了键就重新计时（鼠标停在岛上时计时本来就停着）
    if !isHovered { arm(Self.boardKeyboardDwell) }
    switch Int(event.keyCode) {
    case 53:
      dismiss()
    case 123, 124:
      guard
        let next = Self.moved(
          boardSelection, by: event.keyCode == 123 ? -1 : 1,
          count: quickActions.count)
      else { return }
      boardSelection = next
      Self.announce(quickActions[next].title)
    case 36, 76:
      if let index = boardSelection, quickActions.indices.contains(index) {
        perform(quickActions[index], checked: false)
      }
    default:
      break
    }
  }

  /// ←→ 选快捷动作（纯函数）：到头回绕；还没选中时从第一个起；没有快捷动作是 nil
  static func moved(_ selection: Int?, by step: Int, count: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let selection else { return 0 }
    return ((selection + step) % count + count) % count
  }

  /// 收起 / 换成别的提示时把键盘还回去：叫出之前本 App 里有 key 窗口就还给它；本 App 不在前台（键盘本来在别的 App 里）
  /// 就 deactivate 一次——不激活的面板收起后 AppKit 会把 key 交给本进程别的面板、一直不放（同 NoteFloats.returnKeyboard）
  private func releaseKeyboard() {
    guard holdsKeyboard else { return }
    holdsKeyboard = false
    boardSelection = nil
    window?.keyable = false
    window?.onKey = nil
    defer { keyBeforeBoard = nil }
    guard window?.isKeyWindow == true else { return }
    if let previous = keyBeforeBoard, previous.isVisible {
      previous.makeKey()
    } else if !NSApp.isActive {
      NSApp.deactivate()
    }
  }

  /// 双指在岛上往上滑多少算收起（pt，按手指方向）
  static let swipeDistance: CGFloat = 24

  /// 手指往上走了多少：「自然滚动」开着时 scrollingDeltaY 和手指同向（往下为正），关着时相反
  nonisolated static func fingersUp(deltaY: CGFloat, inverted: Bool) -> CGFloat {
    inverted ? -deltaY : deltaY
  }

  private func open(with next: Content) {
    isPeeking = false
    isRetracting = false
    showWindow()
    content = nil
    // 先让形体从刘海 / 小胶囊长开，内容由自己的过渡晚 60 ms 出场
    withAnimation(Style.Motion.island.animation()) {
      isOpen = true
      content = next
    }
  }

  /// 摆好窗口、拿到最前（摆出来的岛不建）。窗口在屏上时不动它（尺寸一次定死，见 Geometry.windowSize）。
  /// 先不接鼠标，指针落在形状上再接（hover）
  private func showWindow(on screen: NSScreen? = nil) {
    guard !isStaged else { return }
    let fresh = self.window == nil
    let window = self.window ?? makeWindow()
    self.window = window
    if !isOpen || !window.isVisible { place(window, on: screen) }
    // 新建的窗口先按收着的样子排一遍，再改状态：SwiftUI 第一次画它时状态要是已经变了（鼓起、展开），就没有动画的起点、
    // 直接画成终点的样子（2026-10-26 用户：「首次启动，hover 没有动画效果」）
    if fresh { window.contentView?.layoutSubtreeIfNeeded() }
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    watchMouse()
  }

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
  }

  /// 有刘海屏、插件也添加着才常驻监听（点刘海、停在刘海上、耳朵的悬停要它们）；否则照旧显示时装、收起后卸
  private func rewatchNotch() {
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
  private func watchMouse() {
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
    let toggled = click(onNotch: ownsClick && event.clickCount == 1)
    return toggled && local && event.window === window
  }

  /// 点了一下：没有提示时点在刘海上 = 打开 / 收起那一张（屏幕最顶那一行窗口收不到点击，全局监听收得到）；
  /// 那一张开着时点在它外面 = 收起。返回开 / 关过没有
  private func click(onNotch allowed: Bool) -> Bool {
    let mouse = NSEvent.mouseLocation
    if allowed, respondsToNotch, content == nil, !isSuppressed(),
      Self.onNotch(mouse, notches: notchRects)
    {
      toggleBoard()
      return true
    }
    if isBoardOpen, let window, !NSMouseInRect(mouse, shapeOnScreen(window), false) { dismiss() }
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
    window?.ignoresMouseEvents = true
    Task { [weak self] in
      try? await Task.sleep(for: Self.retractTime)
      guard let self, !self.isOpen, !self.isPeeking, !self.isShowingWings else { return }
      self.window?.orderOut(nil)
    }
  }

  private func shapeOnScreen(_ window: NSWindow) -> CGRect {
    let frame = window.frame
    return CGRect(
      x: frame.minX + shapeFrame.minX, y: frame.maxY - shapeFrame.maxY,
      width: shapeFrame.width, height: shapeFrame.height)
  }

  private func unwatchMouse() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  // ponytail: 指针停在本 App 不收鼠标移动的窗口（设置窗）上、又正好在岛下面时，本地监听收不到移动，不会展开
  // （离开由 hoverCheck 兜住）；岛在屏幕最顶上，和面板、设置窗叠到的机会很小，真碰到再给那几扇窗口开 acceptsMouseMovedEvents
  private func track() {
    let mouse = NSEvent.mouseLocation
    if content != nil || isBoardOpen {
      if let window { hover(NSMouseInRect(mouse, shapeOnScreen(window), false)) }
      return
    }
    // 刚收起、还在缩回时不鼓
    guard !isOpen, !isRetracting else { return }
    let onWings =
      isShowingWings && window.map { NSMouseInRect(mouse, shapeOnScreen($0), false) } == true
    peek(
      !isSuppressed() && (onWings || (respondsToNotch && Self.onNotch(mouse, notches: notchRects))))
  }

  /// 放到鼠标所在屏（耳朵给的是刘海屏）顶部正中（刘海屏贴着顶边，其它屏在菜单栏下方）。只在窗口不在屏上时调
  private func place(_ window: IslandPanel, on target: NSScreen? = nil) {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = target
        ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    else { return }
    geometry = Self.geometry(of: screen)
    let size = geometry.windowSize
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    let top =
      if case .notch = geometry { screen.frame.maxY } else { screen.frame.maxY - menuBar - 8 }
    window.setFrame(
      CGRect(
        x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width,
        height: size.height),
      display: false)
    host?.rootView = IslandView(island: self)
  }

  static func geometry(of screen: NSScreen) -> Geometry {
    geometry(
      width: screen.frame.width, left: screen.auxiliaryTopLeftArea,
      right: screen.auxiliaryTopRightArea, safeTop: screen.safeAreaInsets.top,
      menuBar: screen.frame.maxY - screen.visibleFrame.maxY, systemIsland: hasSystemIsland(screen))
  }

  /// 刘海：左右两块 auxiliary 区都在、且顶部安全区 > 0；刘海宽 = 屏宽 − 两块区宽 + 4（盖住抗锯齿毛边）。
  /// 系统自己有灵动岛的屏（2026-10-28 发布的 MacBook Pro PROLED XDR，挖孔）当没有刘海：开孔周围那一块归系统
  /// （Spotlight、Siri、实时活动，往下滑叫出 Spotlight），我们不在上面画、不听点和停留，提示退回菜单栏下方的胶囊
  // ponytail: 胶囊照旧在菜单栏下方正中，系统灵动岛往下展开时可能叠上；没有真机，拿到几何（updateNotches 写的日志）再看要不要挪
  static func geometry(
    width: CGFloat, left: CGRect?, right: CGRect?, safeTop: CGFloat, menuBar: CGFloat,
    systemIsland: Bool
  ) -> Geometry {
    if !systemIsland, let left, let right, safeTop > 0 {
      return .notch(width: width - left.width - right.width + 4, height: safeTop)
    }
    return .capsule(menuBar: menuBar)
  }

  /// 这块屏上有没有系统自己的灵动岛。系统没有直接说的接口：macOS 27 起看屏幕支不支持多点触控——目前只有
  /// 这一款 Mac 是触屏，它也是唯一有灵动岛的
  // ponytail: 拿触屏当灵动岛的记号；出了带刘海的触屏 Mac、或者 Apple 给了正式接口，换成那个
  static func hasSystemIsland(_ screen: NSScreen) -> Bool {
    if #available(macOS 27, *) { screen.touchCapabilities.contains(.multiTouch) } else { false }
  }

  private func makeWindow() -> IslandPanel {
    let panel = IslandPanel(
      contentRect: CGRect(origin: .zero, size: geometry.windowSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // 本 App 失活时不收（NSPanel 默认收；收回浮动便签后 NoteFloats.returnKeyboard 会 deactivate 一次）
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // 平时不接鼠标；指针落在形状上才接（hover）。接着的时候指针在岛上移动也要报给本地监听，才知道什么时候出去
    panel.ignoresMouseEvents = true
    panel.acceptsMouseMovedEvents = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    // 宿主包在普通容器里（setHostedContent）：直接当 contentView 时窗口一改大小就在「更新约束」里绕下去、抛异常崩掉
    // （2026-10-26 屏上复现：先弹提示、再在上面开那一张；测试里还见过窗口被它改成 520 × 64）
    let host = IslandHost(rootView: IslandView(island: self))
    host.sizingOptions = []
    host.island = self
    panel.setHostedContent(host)
    self.host = host
    return panel
  }

  /// VoiceOver 主动播报（全 App 同一个入口）：焦点一直在搜索框 / 原文框，或者窗口本来就不接鼠标（岛、钉图、飞行卡片），
  /// 看不到焦点的变化要自己说出来
  static func announce(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  /// 自带实心底的符号（xxx.circle.fill，还有警告默认的三角、强制结束的八角）：「符号一种颜色、底是语气色」的两色画法
  /// 只有它们画得对。别的（裸符号、空心圆）两色会整个画成第一种颜色、语气色不出现，宽的还会撑出前导槽——由岛垫一个
  /// 语气色圆（IslandLeading）。调用处：有圆底变体的传圆底变体，没有的照传，岛来垫
  static func hasPlate(_ symbol: String) -> Bool {
    [".circle.fill", ".triangle.fill", ".octagon.fill"].contains { symbol.hasSuffix($0) }
  }

  private static func symbol(for tone: Tone) -> String {
    switch tone {
    case .success: "checkmark.circle.fill"
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.circle.fill"
    case .progress: "ellipsis.circle.fill"
    }
  }
}

/// 几种常用的按钮（拍板 C1 的表）
extension Island.Action {
  /// 打开系统设置里那一项授权（点岛本身也是它）
  static func settings(for kind: Permissions.Kind) -> Self {
    Self("打开系统设置", opens: true) { kind.openSettings() }
  }

  /// 在访达里选中这个文件 / 文件夹（点岛本身也是它）
  static func reveal(_ url: URL) -> Self {
    Self("在访达中显示", opens: true) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
}

extension [Island.Action] {
  /// 存成的文件：在访达中显示（主按钮，点岛也是它）+ 用默认的 App 打开
  static func file(_ url: URL) -> Self {
    [.reveal(url), Island.Action("打开", opens: true) { NSWorkspace.shared.open(url) }]
  }
}

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
        wings(geometry)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .mask { IslandOutline(shape: shape).animation(curve, value: shape) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .contentShape(IslandOutline(shape: shape))
    .onTapGesture { island.tapped() }
    .onChange(of: shape.frame, initial: true) { island.shapeFrame = shape.frame }
    .modifier(Shake(count: island.shakes, enabled: !reduceMotion))
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
      let size =
        if open {
          CGSize(
            width: max(notchWidth + 64, contentSize.width),
            height: notchHeight + max(Island.chin, contentSize.height))
        } else if wings {
          // 耳朵：刘海两侧各 36，和刘海同高；指针停上去同样鼓起一圈
          CGSize(
            width: notchWidth + Island.wing * 2 + (peek ? Island.peekGrow.width * 2 : 0),
            height: notchHeight + (peek ? Island.peekGrow.height : 0))
        } else if peek {
          CGSize(
            width: notchWidth + Island.peekGrow.width * 2,
            height: notchHeight + Island.peekGrow.height)
        } else {
          IslandGeometry.tucked(notchWidth: notchWidth, notchHeight: notchHeight)
        }
      return IslandGeometry(
        frame: CGRect(x: (canvas - size.width) / 2, y: 0, width: size.width, height: size.height),
        ear: open ? 10 : (peek ? 8 : (wings ? 6 : 0)),
        bottom: open
          ? (island.isExpanded || island.isBoardOpen ? 24 : 22) : (peek ? 13 : (wings ? 12 : 8)),
        floor: IslandGeometry.tucked(notchWidth: notchWidth, notchHeight: notchHeight),
        contentTop: notchHeight, capsule: false)
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
    if island.isOpen { return Style.Motion.island.animation() }
    return island.isPeeking ? Style.Motion.pop.animation() : Style.Motion.retract.animation()
  }

  /// 黑底：刘海屏纯黑带耳朵，无刘海屏 black 0.92 + 发丝线的圆角卡片；只有开着时有阴影（挂在纯形体上，不挂在内容上）
  /// 不按两种屏分支（分支一换就是新视图，动画没有起点）：两种屏只是颜色、描边的参数不同
  private func backdrop(_ shape: IslandGeometry) -> some View {
    let outline = IslandOutline(shape: shape)
    return outline.fill(.black.opacity(shape.capsule ? 0.92 : 1))
      .overlay(outline.hairlineBorder(.white.opacity(shape.capsule ? 0.12 : 0)))
      .islandShadow(open: island.isOpen)
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
      } else if let content = island.content {
        Group {
          if island.isExpanded {
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

  /// 耳朵上的两小块（收起、有活动时）：画在刘海那一行里，不垫刘海高度；换了露的活动就交叉淡入
  @ViewBuilder private func wings(_ geometry: Island.Geometry) -> some View {
    if case .notch(let width, let height) = geometry, island.isShowingWings, !island.isOpen,
      let activity = island.activity
    {
      IslandWings(activity: activity, notchWidth: width, notchHeight: height)
        .id(activity.id)
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }
  }

  /// 内容量好的大小：岛上有东西时才记（收起后退场的那一份不覆盖，形体照最后一份缩回）
  private func report(_ size: CGSize) {
    guard island.content != nil || island.isBoardOpen, size.width > 0 else { return }
    contentSize = size
  }

  /// 内容出场：晚 60 ms，blur 8 → 0、scale 0.9 → 1（顶部锚点）、透明度（smooth 0.28）；退场 0.12 s 淡出。
  /// 形体那边同时在长，内容被它裁着出来
  private var appear: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .modifier(
          active: Emerge(progress: 0), identity: Emerge(progress: 1)
        ).animation(.smooth(duration: 0.28).delay(0.06)),
        removal: .opacity.animation(.easeIn(duration: 0.12)))
  }

  private func row(_ content: Island.Content) -> some View {
    HStack(spacing: 10) {
      IslandLeading(content: content)
      title(content)
      if let activity = island.cardActivity { IslandActivityReading(activity: activity) }
      fractionBar(content)
      if let detail = content.detail {
        Text(detail)
          .font(detailFont(content))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 280, alignment: .leading)
      }
      if let first = island.actions.first {
        IslandButton(title: first.title, prominent: false) { island.perform(first) }
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
          ForEach(Array(island.actions.enumerated().reversed()), id: \.offset) { index, action in
            IslandButton(title: action.title, prominent: index == 0) { island.perform(action) }
          }
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
      if let detail = content.detail {
        Text(detail)
          .font(detailFont(content))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 32)
          .padding(.bottom, 12)
      }
    }
    .padding(.horizontal, 18)
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
      let ink = content.tone == .info || content.tone == .progress ? Style.onBrand : .white
      Group {
        if Island.hasPlate(content.symbol) {
          Image(symbol: content.symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(ink, Self.tint(content.tone))
        } else {
          // 没有圆底变体的符号：垫一个语气色圆。圆是同字号的 circle.fill，和 xxx.circle.fill 的圆一样大（约 18.5 pt）；
          // 符号放进 12 × 12（和系统圆底符号里的那个差不多大），宽的（键盘、带角标的文件夹）跟着缩，不出圆
          Image(systemName: "circle.fill")
            .foregroundStyle(Self.tint(content.tone))
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

  static func tint(_ tone: Island.Tone) -> Color {
    switch tone {
    case .success: Color(nsColor: .systemGreen)
    case .info, .progress: Style.brand
    case .warning: Color(nsColor: .systemOrange)
    case .error: Color(nsColor: .systemRed)
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

/// 岛上的胶囊按钮：12 semibold、高约 22；主按钮（展开后最右那个）白底黑字，其余 white 0.16 底白字
struct IslandButton: View {
  let title: String
  let prominent: Bool
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
    }
    .buttonStyle(IslandButtonStyle())
    .accessibilityLabel(title)
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
    let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    return min(max(widest.rounded(.up), minWidth), maxWidth)
  }
}

extension View {
  /// 展开态的阴影（mac-whisker §3「层级」：black 0.45 / 模糊 14 / 向下 6）：刘海下巴和无刘海的胶囊同一组
  fileprivate func islandShadow(open: Bool) -> some View {
    shadow(color: .black.opacity(open ? 0.45 : 0), radius: 14, y: 6)
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
    AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
  {
    get {
      AnimatablePair(
        AnimatablePair(shape.frame.width, shape.frame.height),
        AnimatablePair(shape.ear, shape.bottom))
    }
    set {
      shape.frame.origin.x += (shape.frame.width - newValue.first.first) / 2
      shape.frame.size = CGSize(width: newValue.first.first, height: newValue.first.second)
      shape.ear = newValue.second.first
      shape.bottom = newValue.second.second
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
      x: canvas.midX - width / 2, y: canvas.minY + shape.frame.minY, width: width, height: height
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

/// 岛的窗口：无边框窗口默认当不了 key，「那一张」用快捷键叫出时要临时当 key 收 Esc / ←→ / ↩（U9）——只为这个子类化
/// （mac-overlay-panel §1 的例外）。平时 keyable 是 false，同普通的 NSPanel、当不了 key。当着 key 的那几秒里按键全归岛：
/// 普通键在 sendEvent 里交给岛（岛不认的也吞掉、不响），带 ⌘ 的组合在 performKeyEquivalent 里吞掉（不让 ⌘Q 退出本 App、
/// ⌘, 开设置）；都不进响应链
final class IslandPanel: NSPanel {
  var keyable = false
  var onKey: ((NSEvent) -> Void)?

  override var canBecomeKey: Bool { keyable }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if keyable, event.type == .keyDown {
      onKey?(event)
      return
    }
    super.sendEvent(event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    keyable || super.performKeyEquivalent(with: event)
  }
}

/// 岛的宿主：接着鼠标时第一下点击就给按钮（本 App 不在前台时也一样，G23）；指针在岛上时双指往上滑收起。
/// 平时窗口整个不接鼠标，这两样都不起作用
private final class IslandHost: NSHostingView<IslandView> {
  weak var island: Island?
  /// 这一次手势里手指往上走了多少（往下是负的）；够了收 / 开一次，同一次手势不再算
  private var swipe: CGFloat = 0
  private var swiped = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func scrollWheel(with event: NSEvent) {
    // 只认触控板的手势阶段（鼠标滚轮、惯性阶段的 phase 是空的）
    guard event.phase != [] else { return }
    if event.phase == .began {
      swipe = 0
      swiped = false
    }
    guard !swiped else { return }
    swipe += Island.fingersUp(
      deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice)
    if swipe >= Island.swipeDistance {
      swiped = true
      island?.swipeAway()
    } else if swipe <= -Island.swipeDistance {
      swiped = true
      island?.swipeDown()
    }
  }
}
