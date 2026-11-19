// 刘海岛（Whisker 招牌时刻 S2，mac-whisker §5）：全局轻提示从刘海里长出来；没有刘海的屏幕上是菜单栏下方的黑色胶囊。
// 一个尺寸固定、平时不抢键盘的透明窗口（IslandPanel：只为「那一张」用快捷键叫出时能临时当 key，level 状态栏）放在鼠标所在屏顶部正中，
// 只让 SwiftUI 里的岛形状变形，不动画窗口 frame。内容晚 60 ms 出场；原地更新（翻译中 → 已替换）只换宽度；
// 错误时整座岛左右抖一下；消失时先退内容，再缩回刘海。停留：只有标题 1.4 s、带详情 2 s、错误 3 s、带按钮 6 s、进行中一直挂着。
// 能交互（2026-10-26 拍板，全部按推荐）：鼠标挪到岛上就停住计时、往下长成卡片（完整详情、全部按钮、×），离开 1.5 s 后收；
// 点岛本身执行「打开」类的按钮；双指往上滑收起；鼠标在岛上时来的新提示先排着。窗口平时不接鼠标，只在指针落在
// 画出来的形状上时才接（全局 + 本 App 的鼠标移动监听按位置开关），透明处和阴影那一圈照旧点穿。
// 主动叫出来（同日用户「不能手动交互吗」，三项按推荐）：没有提示时点刘海（指针停在刘海上岛先鼓起一点），或者按
// 「打开刘海岛」的快捷键（哪块屏都行），长出「那一张」：一排快捷动作，设置里打开时再列本次启动以来最近 10 条提示
// （IslandBoard.swift；快捷动作开哪几个、什么先后，列不列提示（2026-11-14 起默认不列），在 设置 › 刘海岛，2026-11-12 PR #17）。
// 用快捷键叫出的那一张临时当 key（第四轮体检 U9）：Esc 收、←→ 选快捷动作、↩ 执行，到点自己收（同平时的岛）；收起时键盘
// 还给原来那扇窗口 / 原来的 App。点刘海叫出的照旧不抢键盘。按快捷键时岛上正挂着带按钮的提示 / 卡片（撤销、恢复、重试、停止、
// 加入会议……）：先把键盘交给这几个按钮（第五轮体检 A2：展开成卡片，↩ 执行选中的、←→ 换、Esc 收），再按一次才是那一张。
// 活动（2026-11-13，刘海岛扩展 B1–B3，IslandActivity.swift）：一直挂着的状态（录制中、长任务……）在刘海屏上收起时挂在
// 刘海两侧的耳朵上；指针停上去鼓起一点。**一个刘海只有一张面**（2026-11-14）：有活动时点耳朵、点刘海、往下滑、停一下，
// 开的都是最要紧那个活动的卡片（openTop），再往下滑 / 再点刘海轮到下一个活动、最后是那一张（rotate）；没有活动时点刘海
// 才是那一张。提示收起后缩回耳朵。
// 挂着直到处理（pin，2026-11-04 提醒 C2）：到点的提醒不到点收起，中间来的别的提示先显示、收起后换回它；只有它的按钮、×、
// 双指上滑收得掉（×、上滑告诉调用方「处理了」）。一次只挂一条（几条提醒由调用方合成一条）。
// 活动、那一张和键盘、听刘海和鼠标拆在同目录的 Island+Activity / +Board / +Notch.swift，画面在 IslandView.swift（第五轮体检 H1）。

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
    /// 显示的字：换上来时就按当前语言取好（最近的提示里存的也是它）
    var title: String
    var detail: String?
    var tone: Tone
    var symbol: String
    var leading: Leading
    /// 进行中、且知道做到哪了（0…1：更新包下载、转 GIF、压缩）：标题后面多一条细进度条。nil = 不画
    var fraction: Double?
    /// 圆底换成这个颜色（不跟语气走；活动自己的颜色：专注模式、日历的颜色），上面的符号是白的
    var tint: NSColor?
    /// 认这一条用的（多语言，2026-11-15）：进度、收起、缩进耳朵的编号按它找这一条（progress、dismiss(ifShowing:)），
    /// 不拿显示出来的字比——两句不同的中文可能译成同一句英文。key + 插进去的值都算
    var source: LocalizedStringResource
    /// 挂着直到处理的那条（pin 换上来的，提醒）：按钮一开始就全露着，展开不重排（IslandView.pinnedCard）
    var isPinned = false

    /// 标题、说明是能本地化的字（调用处的字面量会被抽进目录）；用户的数据（歌名、文件名）传 "\(x)"
    init(
      title: LocalizedStringResource, detail: LocalizedStringResource? = nil, tone: Tone,
      symbol: String, leading: Leading, fraction: Double? = nil
    ) {
      self.title = String(localized: title)
      self.detail = detail.map { String(localized: $0) }
      self.tone = tone
      self.symbol = symbol
      self.leading = leading
      self.fraction = fraction
      source = title
    }
  }

  /// 岛上的一个按钮。第一个是最主要的：平时露在行尾，展开后在 × 左边（拍板 B2）；挂着的那条一开始就全露着、主按钮在最右
  struct Action {
    /// 显示的字（建的时候按当前语言取好）
    let title: String
    /// 打开类（在访达中显示、打开系统设置里那一项、跳到设置的某一页）：点岛本身也执行它（拍板 B3）。
    /// 撤销、取消、重试、继续这类是 false，只能点按钮
    var opens = false
    /// 那一张上的快捷动作画成符号 + 小字（提示上的按钮不用）
    var symbol: String?
    let run: () -> Void

    init(
      _ title: LocalizedStringResource, opens: Bool = false, symbol: String? = nil,
      run: @escaping () -> Void
    ) {
      self.title = String(localized: title)
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
  var content: Content?
  /// 形体展开着
  var isOpen = false
  /// 每次出错 +1，触发抖动
  private(set) var shakes = 0
  /// 这一条的按钮；内容换了就跟着换
  var actions: [Action] = []
  /// 鼠标停在岛上（指针动过、落在形状里才算，拍板 B6）
  var isHovered = false
  /// 正按着拖岛上的东西（播放卡片的进度条）：拖出岛外也照旧算指针在岛上，松手再按位置算（holdPointer）
  @ObservationIgnored var isDragging = false
  /// 长成了卡片：悬停时展开；离开后照旧开着直到收起（进行中的离开就合上，它还要挂着）
  var isExpanded = false
  /// 「那一张」开着：点刘海、快捷键「打开刘海岛」叫出来的（快捷动作 + 最近的提示，IslandBoard）
  var isBoardOpen = false { didSet { syncFullScreenAlpha() } }
  /// 没有提示、没开那一张时指针停在刘海上：岛轻轻鼓起一点，告诉你能点
  var isPeeking = false
  /// 最近的提示：本次启动以来最近 historyLimit 条，新的在前；进行中的不记
  private(set) var history: [Record] = []
  /// 那一张上的快捷动作：打开时从 boardActions 取一次
  var quickActions: [Action] = []
  /// 那一张上列不列最近的提示（设置 › 刘海岛，Prefs.islandShowsHistory）：打开时读一次。不列也照样记着
  var showsHistory = true
  /// 那一张上的月历（设置 › 刘海岛「日程」，Prefs.islandCalendar；IslandCalendar.swift）：打开时读一次——哪一天
  /// （nil = 不显示）、今天的日程（nil = 没有「日历」授权）
  var calendarDay: Date?
  var agenda: Agenda?
  /// 今天的日程从哪来（AppDelegate 接到 NextEvent.agenda；岛自己不碰 EventKit）。没授权返回 nil
  @ObservationIgnored var agendaProvider: (() -> Agenda?)?
  /// 一直挂着的活动（IslandActivity.swift）；耳朵上露最要紧的一个（activity）
  var activities: [Activity] = []
  /// 耳朵该露着：有活动、有刘海屏。提示、那一张开着时照旧是它们，收起后缩回耳朵（不缩进刘海、窗口不移走）
  var isShowingWings = false
  /// 展开着的卡片是哪个活动的（点耳朵展开的）：它更新时卡片原地换，结束时收起；卡片上标题旁边挂它的实时读数
  var expandedActivity: String?
  /// 没有刘海屏时活动挂在菜单栏里（刘海岛扩展 H1，IslandMenuItem）
  @ObservationIgnored lazy var menuItem: IslandMenuItem = {
    let item = IslandMenuItem()
    item.onClick = { [weak self] in self?.expand($0) }
    return item
  }()
  /// 点刘海、停在刘海上、两指往下滑打开（设置 › 刘海岛「点刘海打开」，刘海岛扩展 G2；AppDelegate 跟着偏好给）。
  /// 关着时这几样都不响应，快捷键照样能叫出来；耳朵上的活动照常能停、能点
  @ObservationIgnored var respondsToNotch = true
  /// 停在耳朵上自动展开最要紧的那个活动（设置 › 刘海岛，默认关：Alcove 是停上去只鼓起、点了才展开——第 2 批
  /// 以为它是悬停展开，做成了默认开，用户 2026-11-14 指出；AppDelegate 跟着偏好给）
  @ObservationIgnored var hoverExpands = false
  /// 停在刘海上多久自动展开（设置 › 刘海岛，2026-11-17 照 Alcove 能调；默认 hoverExpandDelay）
  @ObservationIgnored var hoverDelay = Island.hoverExpandDelay
  /// 提示停多久的倍数（设置 › 刘海岛「提示停多久」，DwellLength；进行中的不算）
  @ObservationIgnored var dwellScale = 1.0

  /// 提示停多久（设置里三档）
  enum DwellLength: String, CaseIterable {
    case short, standard, long

    var scale: Double {
      switch self {
      case .short: 0.6
      case .standard: 1
      case .long: 1.8
      }
    }
  }
  /// 音量 / 亮度那一行多久收回（设置 › 刘海岛「音量和亮度」；默认 levelDwell）
  @ObservationIgnored var levelStay = Island.levelDwell
  /// 音量 / 亮度的细条用强调色（默认白）、旁边写百分比（默认不写）
  var levelAccent = false
  var levelPercent = false
  /// 刘海屏上的形体描一圈细边（设置 › 刘海岛「描一圈细边」，默认关；2026-11-17 照 Alcove 的对比描边）：深色桌面、
  /// 全屏的黑底上也看得清岛的轮廓。收着时形体藏在真刘海后面，描边也看不见
  var outlined = false
  /// 触感（设置 › 刘海岛「触感反馈」，A5）：滑动切歌、展开活动、进度条拖到头时触控板一下。摆出来的岛不给
  @ObservationIgnored var haptics = true
  /// 点到了岛本身（耳朵、刘海）：整座岛缩一下再弹回（C2；IslandView 看它的次数）
  var presses = 0
  /// 岛上现在是哪个活动的「一瞥」（glance）；不是就是 nil
  @ObservationIgnored var glancing: String?
  /// 岛上现在是音量 / 亮度的那一行（showLevel）；不是就是 nil
  var level: Level? { didSet { syncFullScreenAlpha() } }
  /// 音量 / 亮度到头了还在按（Level.pushed）的次数：每多一次，细条往那一头顶出去一下再弹回（第五轮体检 U13；IslandLevelBar）
  private(set) var levelBumps = 0
  /// 形体现在按音量 / 亮度提示的样子算（刘海两边各伸出一截、不往下长）。比 level 多留一拍：收回时内容先开始退、形体
  /// 晚两帧才缩，这一拍里 level 已经没了、形体得还是提示的样子——不然会按上一份内容的大小往下鼓出一块空的再缩回
  var levelShaped = false
  /// 形体捏回刘海（每侧只多 4 pt，里面什么都不画）：换不同种类的内容时先捏一下、再长成新的（2026-11-14 照 Alcove
  /// 的逐帧实录：耳朵 → 音量提示是先缩回刘海约 0.3 秒、再往两边长开约 0.4 秒；音量换亮度、提示收回耳朵同样）
  var pinched = false
  @ObservationIgnored var pinch: Task<Void, Never>?
  /// 形体「坐」在刘海里：和收着时一样窄（藏在真刘海后面），但和刘海一样高。空刘海上出音量 / 亮度提示之前先（不带
  /// 动画）换成它、收回时缩到它为止（缩完再不带动画换回收着的样子）——提示就只往两边长 / 缩，高度不变；直接从收着的
  /// 样子（比刘海矮 6）长的话，两边伸出来的那一截是一边伸一边往下长的（Alcove 的实录里高度一直是刘海的高度）。
  /// 只在刘海屏、岛上空着（没开、没耳朵、没鼓起）时算数：isSeated
  var seated = false
  /// 刚收起的那个音量 / 亮度提示：再留 0.3 秒给画面（IslandView 把它原地淡掉、跟着形体的边往回走；当场拆掉它就
  /// 停在原位、被缩回来的边切掉）。摆出来的岛、减弱动态效果不留
  private(set) var departingLevel: Level?
  @ObservationIgnored private var departing: Task<Void, Never>?
  /// 正捏着、等着出的那个音量 / 亮度（捏的时候又按了键就换成最新的）
  @ObservationIgnored var pendingLevel: Level?
  /// 捏多久再长出来
  static let pinchTime = Duration.milliseconds(240)
  @ObservationIgnored var hoverExpand: Task<Void, Never>?
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
  var boardSelection: Int?
  /// 键盘交给了提示 / 卡片上的按钮（快捷键「打开刘海岛」，第五轮体检 A2）：选中的是 actions 里第几个（0 = 主按钮）；没交是 nil
  var buttonSelection: Int?
  /// 那一张是用快捷键叫出的、正临时拿着键盘（或者键盘交给了提示上的按钮）：收起时还回去
  @ObservationIgnored var holdsKeyboard = false
  /// 键盘交给进行中的提示、挂着的提醒（它们不到点收起）之后多久没按键就还回去
  @ObservationIgnored var keyIdle: Task<Void, Never>?
  /// 叫出那一张之前本 App 里当 key 的窗口（固定着的剪贴板面板、设置窗）：还键盘时还给它
  @ObservationIgnored weak var keyBeforeBoard: NSWindow?
  /// 快捷动作从哪来（AppDelegate 给：截图、录屏、录音、识字、截图翻译、快速记一条，照设置里的先后；关掉的、关着的功能不给）
  @ObservationIgnored var boardActions: () -> [Action] = { [] }
  /// 各块屏上硬件刘海的位置（屏幕坐标）：屏幕变了就重算
  @ObservationIgnored var notchRects: [CGRect] = []
  /// start() 过、而且有刘海屏：监听一直装着（点刘海、停在刘海上要它们），收起后不卸。没有刘海的 Mac 照旧显示时装、收起后卸
  @ObservationIgnored var watchesNotch = false
  /// 收起后形体还在缩回（retract 动画那 0.34 s）：这时不鼓，免得把还在缩的窗口改回小的、截掉一截
  @ObservationIgnored var isRetracting = false
  /// 这会儿不响应刘海（AppDelegate 给：截图 / 录屏框选中、启动台开着、状态屏里）：点它、停在它上面都不算
  @ObservationIgnored var isSuppressed: () -> Bool = { false }
  @ObservationIgnored var screenObserver: Any?
  @ObservationIgnored var geometry = Geometry.capsule(menuBar: 24)
  @ObservationIgnored var window: IslandPanel?
  @ObservationIgnored var host: IslandHost?
  @ObservationIgnored var dwell: Task<Void, Never>?
  /// 这一条到点收起的时刻；悬停时停住，离开后接着走剩下的（至少 leaveDelay）
  @ObservationIgnored var deadline = ContinuousClock.now
  @ObservationIgnored private var remaining = Duration.zero
  /// 内容换过 / 刚展开的时刻：之后 clickGuard 以内的点击不算（拍板 B6，按钮会挪位置）
  @ObservationIgnored var changedAt: ContinuousClock.Instant?
  /// 上一次换面（展开某个活动的卡片、轮到那一张）的时刻：之后 turnGuard 之内的点刘海 / 往下滑不轮
  @ObservationIgnored var turnedAt: ContinuousClock.Instant?
  /// 鼠标在岛上时来的新提示：移开再换上，只留最新一条（拍板 B5）
  @ObservationIgnored var pending: (content: Content, actions: [Action])?
  /// 挂着直到处理的那一条（提醒，PLAN §10「提醒」C2；pin）：不到点收起，别的提示来了先显示那条、收起后换回它
  @ObservationIgnored private var pinned:
    (content: Content, actions: [Action], onClose: () -> Void)?
  @ObservationIgnored var monitors: [Any] = []
  /// 悬停期间每 0.2 s 再核一次指针：从岛直接挪进本 App 不收鼠标移动的窗口时没有移动事件，靠它发现离开
  @ObservationIgnored var hoverCheck: Task<Void, Never>?
  /// 形状在窗口里的位置（IslandView 量了报上来，左上角原点）：判断指针在不在岛上
  @ObservationIgnored var shapeFrame = CGRect.zero { didSet { syncBackdrop() } }
  /// 展开成大面（卡片、那一张）时四周的渐进模糊（设置 › 刘海岛；IslandBackdrop.swift，私有接口，取不到就没有）
  @ObservationIgnored var blurs = true { didSet { syncBackdrop() } }
  /// 截图、录屏里不出现（设置 › 刘海岛，默认关；2026-11-17 照 Alcove）：窗口的 sharingType 设成 .none，同触发角的面板
  @ObservationIgnored var hidesFromCapture = false {
    didSet { window?.sharingType = hidesFromCapture ? .none : .readOnly }
  }
  /// 刘海那块屏上前台 App 全屏时藏起来（设置 › 刘海岛，默认关；2026-11-18 照 Alcove，IslandFullScreen）：岛在刘海屏上时
  /// 窗口全透明、不接鼠标（AppDelegate 的 isSuppressed 也看它）；跟着指针摆到别的屏上的提示、快捷键叫出来的那一张、
  /// 音量 / 亮度的提示照常（评审：原来整扇窗口透明，那一张看不见却拿着键盘）。换桌面、换前台 App 时看一眼，全屏的动画要约
  /// 0.7 秒，再看两次
  @ObservationIgnored var hidesInFullScreen = false {
    didSet { if oldValue != hidesInFullScreen { watchFullScreen() } }
  }
  @ObservationIgnored private(set) var hiddenForFullScreen = false {
    didSet { if oldValue != hiddenForFullScreen { syncFullScreenAlpha() } }
  }

  /// 现在藏着（窗口在刘海屏上、全屏、不是那一张、不是音量 / 亮度提示）
  var hidesNow: Bool {
    guard hiddenForFullScreen, !isBoardOpen, level == nil, let window,
      let notch = Self.notchScreen
    else { return false }
    return window.screen?.frame == notch.frame
  }

  private func syncFullScreenAlpha() {
    guard let window else { return }
    let alpha: CGFloat = hidesNow ? 0 : 1
    if window.alphaValue != alpha { window.alphaValue = alpha }
  }
  @ObservationIgnored private var fullScreenObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var fullScreenCheck: Task<Void, Never>?

  private func watchFullScreen() {
    let center = NSWorkspace.shared.notificationCenter
    for observer in fullScreenObservers { center.removeObserver(observer) }
    fullScreenObservers = []
    fullScreenCheck?.cancel()
    guard hidesInFullScreen, !isStaged else {
      hiddenForFullScreen = false
      return
    }
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
    ] {
      fullScreenObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.checkFullScreenSoon() }
        })
    }
    checkFullScreenSoon()
  }

  private func checkFullScreenSoon() {
    fullScreenCheck?.cancel()
    fullScreenCheck = Task { [weak self] in
      for wait in [Duration.zero, .milliseconds(800), .milliseconds(1600)] {
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, let self else { return }
        self.hiddenForFullScreen =
          self.hidesInFullScreen
          && Self.notchScreen.map { IslandFullScreen.isFullScreen(on: $0) } ?? false
      }
    }
  }
  @ObservationIgnored private var backdrop: IslandBackdrop?
  /// 语气变了（nil = 收起）：菜单栏图标据此呼吸 / 弹一下（StatusItem.reflect）
  @ObservationIgnored var onToneChange: ((Tone?) -> Void)?

  /// 刘海屏：从刘海长出下巴；其它屏：菜单栏下方的胶囊
  enum Geometry: Equatable {
    case notch(width: CGFloat, height: CGFloat)
    case capsule(menuBar: CGFloat)

    /// 刘海宽；没有刘海的屏是 nil
    var notchWidth: CGFloat? {
      if case .notch(let width, _) = self { width } else { nil }
    }

    /// 窗口尺寸：一次定死成最大的那个（那一张，boardHeight）+ 两侧耳朵与阴影余量——开那一张不改窗口大小，
    /// 改大小会卡一下（窗口服务器的 frame 变化和图层动画不在一个事务里）。开过一次那一张和一直这么高，常驻内存一样
    var windowSize: CGSize {
      switch self {
      case .notch(_, let notch):
        // 底下留 72：四周的渐进模糊往外晕 68（IslandBackdrop.spread；窗口不够大，那一圈在窗口边上就是一道切口）
        // + 那一张列满时 bloom 过冲的那一下
        CGSize(width: Island.canvasWidth, height: notch + Island.boardHeight + 72)
      case .capsule: CGSize(width: Island.canvasWidth, height: Island.boardHeight + 80)
      }
    }
  }

  /// 摆出来的岛（截图自检、单测）：从头到尾不建窗口（收起后再 show 也不会弹到屏幕上）、不给触感，岛上的东西不读
  /// 本机的状态（输出设备）
  @ObservationIgnored let isStaged: Bool

  init() { isStaged = false }

  /// 截图自检、单测直接摆出某一刻的样子；正常使用就是 `Island()`
  /// board：摆出开着的那一张（里面这几条提示）；peeking：摆出指针停在刘海上鼓起的样子
  init(
    showing content: Content?, geometry: Geometry = .capsule(menuBar: 24),
    actions: [Action] = [], expanded: Bool = false, board records: [Record]? = nil,
    quickActions: [Action] = [], peeking: Bool = false, boardSelection: Int? = nil,
    buttonSelection: Int? = nil, showsHistory: Bool = true, activities: [Activity] = [],
    calendarDay: Date? = nil, agenda: Agenda? = nil
  ) {
    isStaged = true
    self.calendarDay = calendarDay
    self.agenda = agenda
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
    self.buttonSelection = buttonSelection
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

  /// 收着那一行的标题、详情最宽多少（纯函数，多语言第 9 批）：整行（左右各 18、前导 26、间距 10、进度条、露出来的按钮——
  /// 平时是第一个，挂着的那条是全部，间距 8）不超过 maxWidth。详情原来就最宽 280、中间截断，标题不截；英文的长标题
  /// （「Finder Menu needs to be turned on once in System Settings」）加上详情、按钮会撑出岛被裁掉（中文的长标题、
  /// 带用户起的名字的也会）。放不下时先把详情压到最窄 120，还不够再截标题的尾巴；放得下时标题不限（nil）、详情 280，
  /// 和原来一样（中文截图逐像素不变）
  static func rowRoom(title: String, detail: String?, buttons: [String], fraction: Bool) -> (
    title: CGFloat?, detail: CGFloat
  ) {
    func width(_ text: String, _ font: NSFont) -> CGFloat {
      (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
    var budget = maxWidth - 36 - 26 - 10
    if fraction { budget -= 56 + 10 }
    if !buttons.isEmpty {
      let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
      budget -=
        buttons.reduce(0) { $0 + width($1, font) + 20 } + CGFloat(buttons.count - 1) * 8 + 10
    }
    let titleWidth = width(title, .systemFont(ofSize: 13, weight: .semibold))
    guard let detail else { return (titleWidth <= budget ? nil : max(budget, 60), 280) }
    budget -= 10
    let detailWidth = min(width(detail, .systemFont(ofSize: 13)), 280)
    if titleWidth + detailWidth <= budget { return (nil, 280) }
    let detailRoom = min(detailWidth, max(120, budget - titleWidth))
    return (max(budget - detailRoom, 60), detailRoom)
  }

  /// 画布（窗口）宽：最宽 460 的岛 + 两侧各 70（耳朵、阴影、渐进模糊往外晕的 68）
  static let canvasWidth: CGFloat = 600
  /// 离开岛后至少再留多久
  static let leaveDelay = Duration.milliseconds(1500)
  static let clickGuard = Duration.milliseconds(300)
  /// 展开成大面（卡片、那一张）时的底角、顶上两侧往外弯的弧（都是二次曲线的参数，看着比同样数字的圆角小一圈）
  static let largeCorner: CGFloat = 44
  static let largeEar: CGFloat = 24

  /// 展开成卡片、开那一张的弹簧（2026-11-14 照 Alcove 的逐帧实录：约 250 ms 到顶、冲过头约 6.5% 再落回）。弹性 0.39
  /// 是逐帧量着定的：内容量好尺寸后形体的目标会变一次，实际的过冲比按参数算的小——0.35 实测约 4%、0.45 约 10%
  /// （还会回落过头）。只给岛的「大面」用：提示那一行、耳朵出现照旧是 Style.Motion.island（0.42 / 0.22，过冲约 2%）——
  /// 一行小东西弹这么大显得晃，Alcove 的提示、一瞥也不过冲。减弱动态效果时同别的曲线退成 0.2 s
  static var bloom: Animation? {
    Style.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.39)
  }
  /// 刚换面之后多久不轮（评审 1）：指针停在刘海上 0.3 秒卡片自己展开了，你那一下点击 / 下滑才到——本意是「打开」，
  /// 不能当成「轮到下一个」把刚出来的卡片又换掉
  static let turnGuard = Duration.milliseconds(800)

  /// 现在能不能轮（纯函数）
  static func canTurn(
    since turned: ContinuousClock.Instant?, now: ContinuousClock.Instant = .now
  ) -> Bool {
    turned.map { now - $0 >= turnGuard } ?? true
  }
  /// 那一张多宽、最高多少（一排快捷动作 + historyLimit 行提示；有月历时月历 + 5 行提示，差不多一样高）
  static let boardWidth: CGFloat = 420
  static let boardHeight: CGFloat = 440
  static let historyLimit = 10
  /// 指针停在刘海上时岛比刘海宽出、长出多少（每侧 8、往下 5）；停在这一圈里也算停在刘海上
  static let peekGrow = CGSize(width: 8, height: 5)

  /// 标题、说明是能本地化的字：调用处写中文字面量就会被抽进目录；用户的数据（文件名、App 名、出错的原文）传 "\(x)"
  func show(
    _ title: LocalizedStringResource, detail: LocalizedStringResource? = nil,
    tone: Tone = .success, symbol: String? = nil,
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
    // 那一张开着时也排着（收起后再出；那一张里的列表当场就有它）；键盘交给了提示上的按钮时同鼠标停着（A2）
    let busy = (isHovered || holdsKeyboard) && content.map { $0.tone != .progress } == true
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
  /// level：这一条是音量 / 亮度的提示（showLevel），连同它一起换上；card：这一条是这个活动的卡片（expand）
  ///
  /// **决定「画哪一种内容」的那几样（expandedActivity、level、glancing、isExpanded、actions）要和 content 在同一个事务里
  /// 改**（settle）：先单独改它们、再 withAnimation 换 content 的话，SwiftUI 会按事务排两遍——第一遍是「旧内容 + 新标记」，
  /// 比如播放卡片的 expandedActivity 清掉了、content 还在，就按普通提示画出一行（强调色圆底的音符 + 歌名）；这一行是不带
  /// 动画插进来的、紧接着带着动画退场，于是每次收起都闪一下（2026-11-14 用户报，逐帧实录抓到）。dismiss、openBoard 同
  func apply(
    _ next: Content, actions: [Action], quiet: Bool = false, announces: Bool = true,
    level: Level? = nil, card: String? = nil
  ) {
    // 那一张开着时换成这一条：键盘还回去
    releaseKeyboard()
    // 离开后照旧展开着的那张卡片：换成新的一条就合上，新提示一律从一行出来；音量提示同（形体不走展开的那条弹簧）
    let collapses = (!isHovered || level != nil) && isExpanded
    // 来的不是音量提示：正捏着等的那个不出了；刚收起、还在淡的那个也不留（不然它的残影会叠在新来的东西上）
    if level == nil {
      departingLevel = nil
      pinch?.cancel()
      pendingLevel = nil
    }
    let settle = { [self] in
      pinched = false
      // 岛上有东西了，「坐着」就不算数了：清掉，免得这一条收起时还按它算（评审 3）；音量提示收回时再置
      seated = false
      glancing = nil
      self.level = level
      levelShaped = level != nil
      // 活动的卡片开着时来了提示 / 按了音量键：收掉它（不然下一次 setActivity 会把内容换回卡片的）
      if let card {
        expandedActivity = card
      } else if !quiet || level != nil {
        expandedActivity = nil
      }
      self.actions = actions
      if collapses { isExpanded = false }
    }
    dwell?.cancel()
    changedAt = .now
    if isOpen, content != nil || isBoardOpen {
      // 原地更新：内容交叉模糊替换，宽度跟着内容走（spring 0.32）；那一张开着时换成这一条
      withAnimation(Self.resize) {
        settle()
        isBoardOpen = false
        content = next
      }
    } else {
      open(with: next, settle: settle, seats: level != nil)
    }
    if next.tone == .error, !quiet { shakes += 1 }
    if next.tone == .progress { collapseLater(next.source) }
    if !quiet { onToneChange?(next.tone) }
    // VoiceOver 不会去读不当 key 的岛：主动播报（一瞥不报：一首歌念一遍太吵）；摆出来的岛（设置里的悬停预览）不报
    if announces, !isStaged {
      Self.post([next.title, next.detail].compactMap { $0 }.joined(separator: Self.comma))
    }
    // 挂着的那条不到点收起（按钮、×、上滑才收）
    if let pinned, next == pinned.content {
      dwell?.cancel()
      return
    }
    // 带按钮的岛多留一会儿：1.4–2 秒来不及挪鼠标去点（G23）
    let seconds: Double =
      switch next.tone {
      case .progress: 60
      case .error: (actions.isEmpty ? 3 : 6) * dwellScale
      default: (actions.isEmpty ? (next.detail == nil ? 1.4 : 2) : 6) * dwellScale
      }
    if isHovered {
      remaining = .seconds(seconds)
    } else {
      arm(.seconds(seconds))
    }
  }

  /// 不带动画地改（形体那条 .animation(curve, value:) 也不接）
  private static func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
  }

  /// 到点收起
  func arm(_ delay: Duration) {
    dwell?.cancel()
    deadline = .now + delay
    dwell = Task { [weak self] in
      try? await Task.sleep(for: delay)
      if !Task.isCancelled { self?.dismiss() }
    }
  }

  /// 岛的宽度跟着内容变时用的曲线
  static var resize: Animation {
    Style.reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.15)
  }

  /// 进行中的岛改详情（更新包下载、转 GIF、压缩的百分比；fraction 是同一个进度，细进度条跟着走）：内容不重新出场、不播报
  /// （一秒几次，旁白会被刷屏），停留重新计时——事情还在做就一直挂着。岛上已经不是这一条（标题对不上、被别的岛换掉了）就不动。
  /// title 和 show 时给的同一个（按 Content.source 认，不比显示的字）
  func progress(
    _ title: LocalizedStringResource, detail: LocalizedStringResource, fraction: Double? = nil
  ) {
    let detail = String(localized: detail)
    // 已经缩进耳朵的：改活动（卡片展开着就原地换），兜底的 60 s 重新计时
    if var activity = activities.first(where: { $0.id == Self.progressID(title) }) {
      activity.detail = detail
      if let fraction { activity.trailing = .fraction(fraction) }
      setActivity(activity)
      expireProgressLater()
      return
    }
    // 排着还没换上的那条：改它，换上来时就是最新的百分比
    if var queued = pending, queued.content.source == title, queued.content.tone == .progress {
      queued.content.detail = detail
      queued.content.fraction = fraction
      pending = queued
      return
    }
    guard isOpen, let content, content.source == title, content.tone == .progress,
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
    _ title: LocalizedStringResource, symbol: String? = nil,
    after delay: Duration = .milliseconds(300),
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
      // 指针移到一瞥上：展开成那个活动的卡片
      if let id = glancing { expand(id) }
      if !isExpanded, !isBoardOpen {
        // 挂着的那条展开时按钮不挪（pinnedCard）：不用防「刚展开」的那一下，快点也算
        if content?.isPinned != true { changedAt = .now }
        withAnimation(Self.bloom) { isExpanded = true }
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
    // 那一张开着时不当场换：离开 1.5 s 到点收起，dismiss 自己会换上排着的那条；键盘还在提示的按钮上（A2）时同样不换，
    // 免得正选着的按钮被顶掉（还键盘、收起时再换上）
    if !isBoardOpen, !holdsKeyboard, let (next, actions) = pending {
      pending = nil
      apply(next, actions: actions)
      return
    }
    // 键盘还在提示的按钮上（A2）：照旧展开着，选中的那个按钮收着时看不见
    if content?.tone == .progress || isShowingPinned, !holdsKeyboard {
      withAnimation(Style.Motion.retract.animation()) { isExpanded = false }
    }
    // 挂着的提醒本来就不到点收起；键盘在它的按钮上时交给 keyIdle（6 秒没按键还键盘、合回一行）。在这里 arm 的话到点
    // dismiss 先还了键盘（连 keyIdle 一起取消）、挂着的那条又不收，卡片就一直展开着（评审 3）
    if holdsKeyboard, isShowingPinned { return }
    arm(max(remaining, Self.leaveDelay))
  }

  /// 按着拖岛上的东西时（播放卡片的进度条）调：拖着的时候不按指针位置算进出——不然拖出岛外一点卡片就开始计时收起、
  /// 窗口不接鼠标；松手（或者拖着的东西没了）再按位置算一次
  func holdPointer(_ on: Bool) {
    guard on != isDragging else { return }
    isDragging = on
    if !on { track() }
  }

  /// 岛上现在就是挂着的那一条
  var isShowingPinned: Bool { pinned != nil && content == pinned?.content }

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

  /// 刚用双指左右滑切了歌（往哪边、第几次）：封面上闪一个箭头
  struct Skip: Equatable {
    var forward: Bool
    var count: Int
  }
  private(set) var skip: Skip?
  /// 刚用双指左右滑切了歌、耳朵露着时：岛往一侧伸出这么多（正 = 往右、下一首；负 = 往左、上一首），那一截里
  /// 出一个箭头，约 0.24 秒后弹回（2026-11-14 照 Alcove 的实录：伸 24 pt，伸 230 ms、回 250 ms）。摆出来的岛不弹回
  private(set) var stretch: CGFloat = 0
  @ObservationIgnored private var stretchBack: Task<Void, Never>?
  static let stretchReach: CGFloat = 24

  /// 双指在岛上左右滑（手指往左 = 下一首，同系统翻页的方向；以 Alcove 为准的那一轮 A3）：正在播放露在耳朵上、它的卡片
  /// 开着时切歌（那一张开着时不认：2026-11-14 起它上面没有播放那一行，切了没处给反馈）。一次手势只切一首（IslandHost.scrollWheel）；这个源不支持上 / 下一首就不动；
  /// 岛上是别的提示、别的活动的卡片时不认
  @discardableResult func swipeTrack(forward: Bool) -> Bool {
    let media = content == nil ? activity?.media : cardActivity?.media
    guard !isBoardOpen, let media, forward ? media.snapshot.canNext : media.snapshot.canPrevious
    else {
      return false
    }
    media.send(forward ? .next : .previous)
    skip = Skip(forward: forward, count: (skip?.count ?? 0) + 1)
    haptic(.generic)
    // 耳朵露着（卡片没开）：岛伸一下——下一首往右、上一首往左（箭头在哪边就往哪边伸，同播放控制里两个按钮的位置；
    // 和手指滑的方向相反）。卡片开着、减弱动态效果时不伸，箭头照旧闪在封面上
    if content == nil, isShowingWings, !Style.reduceMotion {
      stretch = forward ? Self.stretchReach : -Self.stretchReach
      stretchBack?.cancel()
      if !isStaged {
        stretchBack = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(240))
          guard !Task.isCancelled else { return }
          self?.stretch = 0
        }
      }
    }
    return true
  }

  /// 双指在刘海上往下滑（刘海岛扩展 G1，同点刘海）：没开着东西时打开（openTop）；活动的卡片、那一张开着时轮到下一个
  /// （rotate）。指针停在刘海上岛鼓起、窗口接鼠标时才收得到
  func swipeDown() {
    guard respondsToNotch, !isSuppressed() else { return }
    if content == nil, !isBoardOpen {
      openTop()
    } else if isBoardOpen || cardActivity != nil {
      rotate()
    }
  }

  /// 那一张刚由鼠标 / 触控板打开（点刘海、往下滑、轮到它）：指针就停在岛上、没有鼠标移动来报——当它在岛上，窗口才接得到
  /// 紧跟着的那一下往下滑（评审 2）；指针其实不在时 0.2 秒一次的 hoverCheck 会纠正
  private func settleOnBoard() {
    if !isStaged, isBoardOpen { hover(true) }
  }

  /// 打开（一个刘海只有一张面，2026-11-14 用户：悬停出播放卡片、点却出那一张，是两样东西；各家刘海 App 都是悬停、点、
  /// 下滑开同一张面）：有活动 = 最要紧那个活动的卡片；没有 = 快捷动作那一张。点刘海、双指往下滑走这里；悬停只在有活动时
  /// 展开（armHoverExpand），快捷键「打开刘海岛」照旧直接是那一张（键盘只管得了快捷动作）
  func openTop() {
    guard let activity else {
      toggleBoard()
      return settleOnBoard()
    }
    expand(activity.id)
    // 指针就停在岛上（没有鼠标移动来报）：当它在岛上，不然窗口不接鼠标、卡片 2 秒就收
    if !isStaged { hover(true) }
  }

  /// 活动从要紧到不要紧（卡片轮换的先后，同耳朵上露哪个的先后）
  private var ranked: [Activity] {
    activities.sorted { ($0.kind, $0.started) > ($1.kind, $1.started) }
  }

  /// 卡片开着时再往下滑 / 再点一下刘海：轮到下一个活动的卡片，轮完是快捷动作那一张；那一张开着时往下滑回到第一个活动
  /// （没有活动就不动）。别的提示开着时不轮；刚换过面的 0.8 秒里不轮（turnGuard；摆出来的岛不等）
  func rotate() {
    guard isStaged || Self.canTurn(since: turnedAt) else { return }
    let order = ranked
    if isBoardOpen {
      guard let first = order.first else { return }
      expand(first.id)
    } else if let index = order.firstIndex(where: { $0.id == expandedActivity }), content != nil {
      if index + 1 < order.count {
        expand(order[index + 1].id)
      } else {
        haptic()
        turnedAt = .now
        openBoard()
        return settleOnBoard()
      }
    } else {
      return
    }
    if !isStaged { hover(true) }
  }

  /// 挂在岛上直到处理（提醒，PLAN §10「提醒」C2）：不到点收起；中间来了别的提示先显示那条，它收起后换回这一条；
  /// 点它的按钮、点 ×、双指上滑才真的收（×、上滑调 onClose，按钮跑自己的动作）。再 pin 一次 = 换内容（几条提醒合成
  /// 一条，B5），内容一样只换按钮。鼠标正停在别的提示上、那一张开着时先挂着不出，那条收起 / 那一张关掉时换上
  func pin(
    _ title: String, detail: String?, symbol: String, actions: [Action],
    onClose: @escaping () -> Void
  ) {
    var next = Content(
      title: "\(title)", detail: detail.map { "\($0)" }, tone: .info, symbol: symbol,
      leading: .tone)
    next.isPinned = true
    let wasShowing = isShowingPinned
    let same = pinned?.content == next
    pinned = (next, actions, onClose)
    if same {
      if wasShowing {
        self.actions = actions
        buttonsChanged()
      }
      return
    }
    remember(next, actions: actions)
    if isBoardOpen || ((isHovered || holdsKeyboard) && content != nil && !wasShowing) { return }
    apply(next, actions: actions)
  }

  /// 催一下挂着的那条（提醒 C10）：整座岛左右抖一下（同出错时）、再播报一遍；没显示着它就不动。
  /// 指针在岛上时不抖：人已经在看了，抖起来按钮会从指针底下跑开（2026-11-18 用户反馈点错）
  func nudge() {
    guard isShowingPinned, let content else { return }
    if !isHovered { shakes += 1 }
    Self.post([content.title, content.detail].compactMap { $0 }.joined(separator: Self.comma))
  }

  /// 不再挂着（调用方那边处理完了、功能关了）：正显示着就收
  func unpin() {
    guard pinned != nil else { return }
    let showing = isShowingPinned
    pinned = nil
    if showing { dismiss() }
  }

  /// 收起标题是 title 的这一条（没有结果岛的进行中提示，调用方做完了自己收）：正显示着就收，排着就丢掉。
  /// title 和 show 时给的同一个（按 Content.source 认）
  func dismiss(ifShowing title: LocalizedStringResource) {
    endActivity(Self.progressID(title))
    if pending?.content.source == title { pending = nil }
    if content?.source == title { dismiss() }
  }

  /// 点岛本身：耳朵露着、没别的东西时 = 展开最要紧的那个活动；有打开类的按钮就执行它，没有就什么都不做（点得到时已经展开着）。
  /// 点在刘海本身上的那一下由鼠标监听接走（click：打开 / 轮换），到不了这里
  func tapped() {
    if content == nil, !isBoardOpen, isShowingWings {
      presses += 1
      expandActivity()
      // 同点刘海（openTop）：指针就停在岛上，当它在岛上——不然不动指针时卡片 2 秒就收
      if !isStaged, content != nil { hover(true) }
      return
    }
    // 点一瞥 = 展开那个活动的卡片
    if let id = glancing, content != nil { return expand(id) }
    if let open = actions.first(where: \.opens) { perform(open) }
  }

  /// 一瞥（以 Alcove 为准的那一轮 A2，它叫 Quick Peek）：某个活动有新情况（正在播放换了歌）时，从耳朵垂下一小条说一声，
  /// 约 2 秒收回耳朵。不进最近的提示（歌名不留记录）、不播报、菜单栏图标不动。只在它正露在耳朵上、岛上没别的东西
  /// （或者就是它上一次的一瞥：原地换，连着切两首、封面晚到）、指针不在岛上时出；指针移上去、点它都是展开成它的卡片。
  /// 指针在别的屏上时不出：提示跟着指针所在的屏走，一瞥跟过去就成了外接屏上冒一条胶囊、耳朵跟着没了
  func glance(_ id: String, title: String, detail: String?, symbol: String, leading: Leading) {
    // pendingLevel：正捏着等出音量 / 亮度的提示，一瞥别抢（它一出，这次按键就没有提示了）
    guard hasExtras, isShowingWings, content == nil || isGlancing(id), !isBoardOpen, !isPeeking,
      activity?.id == id, isStaged || pointerIsOnNotchScreen, pendingLevel == nil
    else { return }
    apply(
      Content(
        title: "\(title)", detail: detail.map { "\($0)" }, tone: .info, symbol: symbol,
        leading: leading),
      actions: [], quiet: true, announces: false)
    glancing = id
  }

  /// 音量 / 亮度的那一行多久收回（Alcove 的实录：最后一下按键之后约 2.5 秒开始收；原来 1.2 秒是照它连着按的那段
  /// 录像估的，估短了）
  static let levelDwell = Duration.milliseconds(2200)

  /// 音量 / 亮度的那一行（MediaKeys：按了音量键、亮度键）：图标 + 细条 + 百分比，约 2.2 秒收回。已经出着就原地换数、
  /// 重新数时间（按住连发时一秒来十几次：不重新出场）；没出着就从刘海长出来，顶掉岛上别的提示、那一张（提示本来就是
  /// 一瞬的；挂着的提醒收起后会换回来）。不进最近的提示、不播报、菜单栏图标不动
  /// 自己冒出来的那种（耳机连上）：岛上正用着——那一张开着、指针停在带按钮的提示上——时不顶掉它，退回成一条
  /// 普通的提示排着（同 show 的规矩，评审）；别的时候同 showLevel
  func showNotice(_ next: Level, fallback: LocalizedStringResource) {
    let busy = (isHovered || holdsKeyboard) && content.map { $0.tone != .progress } == true
    if isBoardOpen || busy { return show(fallback, tone: .info, symbol: next.symbol) }
    showLevel(next)
  }

  /// 同一种提示正出着、或者正捏着等着出时，原地换上新的数、重新数时间；别的时候什么都不做（不重新出场，也不顶掉
  /// 已经换上来的别的提示）。耳机的电量晚到时用——只看 level 的话，捏着的那 0.24 秒里它还是上一种（评审）
  func updateLevel(_ next: Level) {
    if let waiting = pendingLevel {
      if waiting.identity == next.identity { pendingLevel = next }
      return
    }
    guard level?.identity == next.identity, content != nil else { return }
    level = next
    arm(next.stay ?? levelStay)
  }

  func showLevel(_ next: Level) {
    if next.pushed { levelBumps += 1 }
    // 正捏着：等会儿出的换成最新的这个
    if pendingLevel != nil {
      pendingLevel = next
      return
    }
    if level != nil, content != nil, level?.kind == next.kind {
      level = next
      return arm(next.stay ?? levelStay)
    }
    let swapsKind = level != nil && content != nil
    guard
      Self.squeezes(
        swapsKind: swapsKind, wings: content == nil && !isBoardOpen && isShowingWings,
        // 从耳朵过来时还要指针就在刘海屏上：不然提示是出在指针那块屏上的，在这边捏了白等
        notch: onNotch && (swapsKind || pointerIsOnNotchScreen), staged: isStaged,
        reduceMotion: Style.reduceMotion)
    else { return presentLevel(next) }
    // 从耳朵过来、音量换亮度：先捏回刘海（里面的东西糊着退），再长成它
    pendingLevel = next
    dwell?.cancel()
    pinch?.cancel()
    // 指针刚停到耳朵上：别让「停一下自动展开」抢在前面把卡片开出来（这次按键就没有提示了）
    hoverExpand?.cancel()
    hoverExpand = nil
    withAnimation(.easeIn(duration: 0.12)) { pinched = true }
    pinch = Task { [weak self] in
      try? await Task.sleep(for: Self.pinchTime)
      guard !Task.isCancelled, let self, let latest = self.pendingLevel else { return }
      self.pendingLevel = nil
      self.presentLevel(latest)
    }
  }

  /// 把音量 / 亮度的提示换上（捏着的话同时放开）、开始数收回的时间
  private func presentLevel(_ next: Level) {
    // 进行中的提示（带「停止」的）先排着，这一行收起时换回来（同开那一张时：不然它被顶掉，之后的进度、按钮都没处放）
    if let content, content.tone == .progress { pending = (content, actions) }
    // 活动的卡片开着就收掉它、不留着「展开着」（形体从卡片缩到这一条不走展开的那条弹簧）：都在 apply 里和内容
    // 一起换
    apply(
      Content(title: "\(next.title)", tone: .info, symbol: next.symbol, leading: .tone),
      actions: [], quiet: true, announces: false, level: next)
    // 这一条上没有能点的东西：不算悬停（指针正在被顶掉的卡片上时也放开），窗口不接鼠标——它盖着刘海两边的菜单栏
    hoverCheck?.cancel()
    isHovered = false
    window?.ignoresMouseEvents = true
    arm(next.stay ?? levelStay)
  }

  /// 出音量 / 亮度提示之前要不要先捏回刘海（纯函数）：从耳朵过来、或者提示换了种类（音量 → 亮度）时捏；岛上空着
  /// （直接从刘海长出来）、开着别的东西（卡片、提示、那一张：当场顶掉）时不捏；摆出来的岛、减弱动态效果不捏。
  /// notch：提示会出在刘海屏上——没有刘海的屏上是一行，形体不认「捏着」，捏了只是白等
  static func squeezes(
    swapsKind: Bool, wings: Bool, notch: Bool, staged: Bool, reduceMotion: Bool
  ) -> Bool {
    notch && !staged && !reduceMotion && (swapsKind || wings)
  }

  /// 岛现在摆的是刘海屏的样子
  private var onNotch: Bool {
    if case .notch = geometry { true } else { false }
  }

  /// 岛上现在是音量 / 亮度的提示
  var isShowingLevel: Bool { level != nil && content != nil }
  /// 刘海两边那种提示现在每侧伸出多宽：出着的（或刚收起、还在淡的）那一条的；专注模式的随名字长短（Level.wing）
  var levelWing: CGFloat { (level ?? departingLevel)?.wing ?? Self.levelWing }

  /// 专注模式开着、设置 › 刘海岛「跳动条换成专注模式的图标」打开时：正在播放的右耳画它（SystemFocus 给，平时 nil）
  var focusMark: FocusMark?

  /// 专注模式的符号和颜色（耳朵上替跳动条）
  struct FocusMark: Equatable {
    var symbol: String
    var tint: NSColor
  }

  /// 形体现在按「坐在刘海里」算（seated 只在岛上空着时算数：开着、有耳朵、鼓起时照它们自己的样子）
  var isSeated: Bool { seated && !isOpen && !isShowingWings && !isPeeking }

  /// 岛上现在是不是这个活动的一瞥
  func isGlancing(_ id: String) -> Bool { glancing == id && content != nil }

  /// 岛上现在是一瞥（哪个活动的都算）：耳朵照旧露着，下面只垂一行字
  var isGlance: Bool { glancing != nil && content != nil }

  private var pointerIsOnNotchScreen: Bool {
    Self.notchScreen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
  }

  /// 触控板轻轻一下（手指放在触控板上才有感觉；设置里能关）
  func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
    guard haptics, !isStaged else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }

  /// 慢的进行中提示缩进耳朵、缩进去以后到点收掉（Island+Activity.swift 的 collapseLater、expireProgressLater）
  @ObservationIgnored var collapseTask: Task<Void, Never>?
  @ObservationIgnored var expiryTask: Task<Void, Never>?

  /// 收起：内容糊着退、形体只晚两帧就缩回刘海（一起走），动画结束再移走窗口。鼠标在岛上时排着一条的（点了 ×、按钮，
  /// 或者调用方自己收），直接换成排着的那条
  func dismiss() {
    dwell?.cancel()
    releaseKeyboard()
    guard isOpen else { return }
    // 收的时候不留着「等会儿要出的音量提示」（留着的话之后每次按键都被当成「正捏着」吞掉）
    pendingLevel = nil
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
    isDragging = false
    window?.ignoresMouseEvents = true
    onToneChange?(nil)
    // 内容和形体一起走（2026-11-14 照 Alcove 的实录：收起一开始形体就动、约 0.4 s 走完，内容边模糊边退——IslandView
    // 的 appear 退场）。原来是两拍：内容 0.12 s 淡出、等 0.2 s 形体才缩（用户 2026-10-26 试过同时走觉得没两拍好看，
    // 那次内容是纯淡出；这次是模糊退场，用户看了实录后定的）。形体只晚两帧：让内容先开始糊
    // 决定画哪一种内容的那几样和 content 在同一个事务里清（见 apply 的说明：先清它们会闪出一条普通样式的行）
    withAnimation(.easeIn(duration: 0.12)) {
      content = nil
      isBoardOpen = false
      actions = []
      expandedActivity = nil
      glancing = nil
      // 音量 / 亮度的提示收回耳朵：先捏回刘海，再长成耳朵（下面那个任务放开）
      if levelShaped, isShowingWings, onNotch, !isStaged, !Style.reduceMotion { pinched = true }
      // 收回空刘海：形体当场就开始往中间缩（缩到「坐在刘海里」为止，高度不变），不等下面那两帧——里面的东西是跟着
      // 边走的，形体晚了它们就先在原地糊掉（Alcove 是一起动的）
      if levelShaped, !isShowingWings, onNotch, !isStaged, !Style.reduceMotion {
        seated = true
        isOpen = false
        levelShaped = false
        // 已经在缩了：指针这时碰到刘海不鼓起（下面的任务晚两帧才标，评审 2）
        isRetracting = true
      }
      if level != nil, onNotch, !isStaged, !Style.reduceMotion {
        departingLevel = level
        departing?.cancel()
        departing = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(300))
          guard !Task.isCancelled else { return }
          self?.departingLevel = nil
        }
      }
      level = nil
      isExpanded = false
      isHovered = false
    }
    if pinched {
      pinch?.cancel()
      pinch = Task { [weak self] in
        try? await Task.sleep(for: Self.retractLag + Self.pinchTime)
        guard !Task.isCancelled, let self else { return }
        withAnimation(Style.Motion.retract.animation()) { self.pinched = false }
      }
    }
    syncBackdrop()
    dwell = Task { [weak self] in
      try? await Task.sleep(for: Self.retractLag)
      guard let self, !Task.isCancelled else { return }
      self.isRetracting = true
      withAnimation(Style.Motion.retract.animation()) {
        self.isOpen = false
        self.levelShaped = false
      }
      try? await Task.sleep(for: Self.retractTime)
      guard !Task.isCancelled else { return }
      // 缩完了（已经藏在真刘海后面）：换回收着的样子
      if self.seated { Self.withoutAnimation { self.seated = false } }
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
  static let retractTime = Duration.milliseconds(600)
  /// 收起时形体比内容晚多久开始缩
  private static let retractLag = Duration.milliseconds(30)

  /// 双指在岛上往上滑多少算收起（pt，按手指方向）
  static let swipeDistance: CGFloat = 24

  /// 双指左右滑多少算切歌（比上下滑的多一半：横着的误触更烦，切了歌回不到刚才的进度）
  static let slideDistance: CGFloat = 36

  /// 这一次手势算不算左右滑：横着走够了、而且比竖着走得多。true = 手指往左（下一首），false = 往右；不算是 nil
  static func sideways(slide: CGFloat, swipe: CGFloat) -> Bool? {
    guard abs(slide) >= slideDistance, abs(slide) > abs(swipe) else { return nil }
    return slide > 0
  }

  /// 这一次手势算不算上下滑：竖着走够了、而且不比横着少（斜着往左右滑、竖向先到 24 的不算收起 / 打开）。
  /// true = 手指往上（收起），false = 往下（开那一张）；不算是 nil
  static func upDown(slide: CGFloat, swipe: CGFloat) -> Bool? {
    guard abs(swipe) >= swipeDistance, abs(swipe) >= abs(slide) else { return nil }
    return swipe > 0
  }

  /// 手指往上走了多少：「自然滚动」开着时 scrollingDeltaY 和手指同向（往下为正），关着时相反
  nonisolated static func fingersUp(deltaY: CGFloat, inverted: Bool) -> CGFloat {
    inverted ? -deltaY : deltaY
  }

  /// settle：apply 里那几样决定画哪一种内容的标记，和内容一起换
  private func open(with next: Content, settle: () -> Void = {}, seats: Bool = false) {
    // 形体这会儿真的收在刘海里吗：鼓起着、上一条正在缩回时不是（评审 1：这时不带动画地「坐下」会把形体一帧切进
    // 刘海再长出来；照旧从现在的样子连续长过去）
    let tucked = !isPeeking && !isRetracting
    isPeeking = false
    isRetracting = false
    showWindow()
    content = nil
    // 空刘海上出音量 / 亮度的提示：先坐到刘海的高度（不带动画，藏在真刘海后面看不见），再往两边长
    let sits: Bool
    if seats, tucked, case .notch = geometry, !isShowingWings, !isStaged, !Style.reduceMotion {
      sits = true
    } else {
      sits = false
    }
    // 不坐的时候不在这儿清（清它也得不带动画，会连累同一拍里别的变化）：settle 里和内容一起清
    if sits, !seated { Self.withoutAnimation { seated = true } }
    // 先让形体从刘海 / 小胶囊长开，内容由自己的过渡晚 60 ms 出场
    withAnimation(Style.Motion.island.animation()) {
      settle()
      isOpen = true
      content = next
    }
  }

  /// 现在该不该有渐进模糊：展开成了大面（卡片、那一张），不是音量 / 亮度的提示。用到的都是被观察的属性：
  /// IslandView 看着它，它一变就调 syncBackdrop——形体的大小碰巧没变（没有刘海的屏上收起再开同一张、减弱动态效果时
  /// 形体一直是开着的大小）时 shapeFrame 不报，光靠它会漏（评审 B）
  var wantsBackdrop: Bool {
    isOpen && (content != nil || isBoardOpen)
      && (isExpanded || isBoardOpen || cardActivity != nil) && !levelShaped
  }

  /// 现在四周有渐进模糊（这时阴影换成又宽又淡的一圈，见 islandShadow）
  var blursNow: Bool {
    backdrop != nil && blurs && wantsBackdrop
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  /// 渐进模糊跟上岛现在的样子：展开成大面时照形体的目标位置出一圈，别的时候收掉。形体的位置变了（IslandView 报
  /// shapeFrame）、该不该有变了（IslandView 看着 wantsBackdrop）、收起（dismiss）、设置变了时调
  func syncBackdrop() {
    guard let backdrop, let container = backdrop.superview else { return }
    guard blurs, wantsBackdrop, shapeFrame.height > 0
    else { return backdrop.hide(animated: !Style.reduceMotion) }
    let notch: Bool
    if case .notch = geometry { notch = true } else { notch = false }
    backdrop.show(
      around: IslandBackdrop.Shape(
        frame: CGRect(
          x: shapeFrame.minX, y: container.bounds.height - shapeFrame.maxY, width: shapeFrame.width,
          height: shapeFrame.height),
        corner: notch ? Self.largeCorner : 18, flatTop: notch),
      animated: !Style.reduceMotion)
  }

  /// 摆好窗口、拿到最前（摆出来的岛不建）。窗口在屏上时不动它（尺寸一次定死，见 Geometry.windowSize）。
  /// 先不接鼠标，指针落在形状上再接（hover）
  func showWindow(on screen: NSScreen? = nil) {
    guard !isStaged else { return }
    let fresh = self.window == nil
    let window = self.window ?? makeWindow()
    self.window = window
    if !isOpen || !window.isVisible { place(window, on: screen) }
    // 新建的窗口先按收着的样子排一遍，再改状态：SwiftUI 第一次画它时状态要是已经变了（鼓起、展开），就没有动画的起点、
    // 直接画成终点的样子（2026-10-26 用户：「首次启动，hover 没有动画效果」）
    if fresh { window.contentView?.layoutSubtreeIfNeeded() }
    window.ignoresMouseEvents = true
    syncFullScreenAlpha()
    window.orderFrontRegardless()
    watchMouse()
  }

  /// 放到鼠标所在屏（耳朵给的是刘海屏）顶部正中（刘海屏贴着顶边，其它屏在菜单栏下方）。只在窗口不在屏上时调
  func place(_ window: IslandPanel, on target: NSScreen? = nil) {
    guard let screen = target ?? NSScreen.underMouse else { return }
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
    #if compiler(>=6.4)
      if #available(macOS 27, *) { screen.touchCapabilities.contains(.multiTouch) } else { false }
    #else
      false
    #endif
  }

  func makeWindow() -> IslandPanel {
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
    panel.sharingType = hidesFromCapture ? .none : .readOnly
    // 宿主包在普通容器里（setHostedContent）：直接当 contentView 时窗口一改大小就在「更新约束」里绕下去、抛异常崩掉
    // （2026-10-26 屏上复现：先弹提示、再在上面开那一张；测试里还见过窗口被它改成 520 × 64）
    let host = IslandHost(rootView: IslandView(island: self))
    host.sizingOptions = []
    host.island = self
    panel.setHostedContent(host)
    self.host = host
    // 宿主下面垫一层：展开时四周的渐进模糊（这一版系统上用不了就不垫）
    if IslandBackdrop.isAvailable, let container = panel.contentView {
      let backdrop = IslandBackdrop(frame: container.bounds)
      backdrop.autoresizingMask = [.width, .height]
      container.addSubview(backdrop, positioned: .below, relativeTo: host)
      self.backdrop = backdrop
    }
    return panel
  }

  /// VoiceOver 主动播报（全 App 同一个入口）：焦点一直在搜索框 / 原文框，或者窗口本来就不接鼠标（岛、钉图、飞行卡片），
  /// 看不到焦点的变化要自己说出来
  /// 能本地化的字：调用处的字面量会被抽进目录；已经是取好的字（标题、用户的数据）用 post
  static func announce(_ text: LocalizedStringResource) { post(String(localized: text)) }

  /// 播报一段已经取好的字
  static func post(_ text: String) {
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  /// 键盘换了选中、换了状态，焦点却没动（启动器、剪贴板、翻译历史、App 快捷键的 ↑↓，⌘K 菜单，便签任务的 ⌘T）：
  /// 读屏开着时说「标题，种类」（第五轮体检 A1 A4）。连按时只说停下来的那一下（0.15 s 内再来的顶掉前一句）；
  /// 读屏没开什么都不做。两段字到真要说的那一刻才取（读屏没开、连按被顶掉的不白算：剪贴板的摘要要整段收拾），
  /// 标题太长的只说前 100 个字。面板收起时还没说的那句作废（cancelSettled）
  static func announceSettled(
    _ title: @escaping @autoclosure () -> String,
    _ detail: @escaping @autoclosure () -> String? = nil
  ) {
    guard NSWorkspace.shared.isVoiceOverEnabled else { return }
    settling?.cancel()
    settling = Task {
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let parts = [String(title().prefix(100)), detail()].compactMap { $0 }.filter { !$0.isEmpty }
      post(parts.joined(separator: comma))
    }
  }

  /// 还没说出来的那一句不说了（浮层收起：↩ 执行、Esc 关掉之后不该再念上一行）
  static func cancelSettled() {
    settling?.cancel()
    settling = nil
  }

  /// 等着说的那一句（announceSettled 的节流）
  private static var settling: Task<Void, Never>?

  /// 自带实心底的符号（xxx.circle.fill，还有警告默认的三角、强制结束的八角）：「符号一种颜色、底是语气色」的两色画法
  /// 只有它们画得对。别的（裸符号、空心圆）两色会整个画成第一种颜色、语气色不出现，宽的还会撑出前导槽——由岛垫一个
  /// 语气色圆（IslandLeading）。调用处：有圆底变体的传圆底变体，没有的照传，岛来垫
  static func hasPlate(_ symbol: String) -> Bool {
    [".circle.fill", ".triangle.fill", ".octagon.fill"].contains { symbol.hasSuffix($0) }
  }

  /// 几段字连成一句时的分隔（播报、读屏的标签）：中文「，」、英文「, 」
  static var comma: String { String(localized: "list.separator", defaultValue: "，") }

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

/// 岛的窗口：无边框窗口默认当不了 key，「那一张」用快捷键叫出时要临时当 key 收 Esc / ←→ / ↩（U9）——只为这个子类化
/// （mac-overlay-panel §1 的例外）。平时 keyable 是 false，同普通的 NSPanel、当不了 key。当着 key 的那几秒里按键全归岛：
/// 普通键在 sendEvent 里交给岛（岛不认的也吞掉、不响），带 ⌘ 的组合在 performKeyEquivalent 里吞掉（不让 ⌘Q 退出本 App、
/// ⌘, 开设置）；都不进响应链
final class IslandPanel: NSPanel {
  var keyable = false
  var onKey: ((NSEvent) -> Void)?
  /// 拿着键盘时被别的窗口拿走了（点了别的 App、别处）：岛还键盘（第五轮体检 A2 评审 5）
  var onResign: (() -> Void)?

  override var canBecomeKey: Bool { keyable }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResign?()
  }

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
final class IslandHost: NSHostingView<IslandView> {
  weak var island: Island?
  /// 这一次手势里手指往上走了多少（往下是负的）、往左走了多少（往右是负的）；够了收 / 开 / 切歌一次，同一次手势不再算
  private var swipe: CGFloat = 0
  private var slide: CGFloat = 0
  private var swiped = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func scrollWheel(with event: NSEvent) {
    // 只认触控板的手势阶段（鼠标滚轮、惯性阶段的 phase 是空的）
    guard event.phase != [] else { return }
    if event.phase == .began {
      swipe = 0
      slide = 0
      swiped = false
    }
    guard !swiped else { return }
    swipe += Island.fingersUp(
      deltaY: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice)
    // 横着的同一个换算：「自然滚动」开着时 scrollingDeltaX 和手指同向（往右为正）
    slide += Island.fingersUp(
      deltaY: event.scrollingDeltaX, inverted: event.isDirectionInvertedFromDevice)
    if let forward = Island.sideways(slide: slide, swipe: swipe) {
      // 没切成（岛上不是正在播放、这个方向不支持）不占这一次手势：接着往上滑照样收得掉
      if island?.swipeTrack(forward: forward) == true { swiped = true }
    } else if let up = Island.upDown(slide: slide, swipe: swipe) {
      swiped = true
      if up { island?.swipeAway() } else { island?.swipeDown() }
    }
  }
}
