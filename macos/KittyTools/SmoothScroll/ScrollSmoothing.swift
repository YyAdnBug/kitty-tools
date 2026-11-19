// 平滑滚动（插件，2026-11-17，issue #14；拍板页 C1 C2，PLAN §10「平滑滚动」）的纯函数，单测锁住（SmoothScrollTests）。
// 行为对标 Mos（CC BY-NC 4.0：只看行为、不拷代码），做法是通用的「目标 + 指数逼近」：
// - 归不归它管（decide）：平滑只管鼠标滚轮——一格一格的、不连续的事件；连续的、带滚动 / 惯性阶段的（触控板、妙控鼠标）不平滑。
//   妙控鼠标（按发送设备认，ScrollTap.isMagicMouse）只照两个反向开关就地反过来，同一下从开始到惯性的每个事件都反（开始那个
//   行数是 0、像素不是 0，2026-11-18 用户的妙控鼠标实测）；触控板原样放过。Mos 按「有阶段就是触控板」认，分不出妙控鼠标。
//   停用的 App 在前台时整个不管（不平滑、不反向）。修饰键：⌥ 按着时不平滑（临时关掉）；⇧ 按着时改成左右滚（照样平滑）；
//   ⌘ / ⌃ 按着时不平滑（缩放这类交给 App 和系统）。反向不看修饰键，照样反；⇧ 按着时拨的还是上下那个滚轮，跟着「上下反向」。
//   平滑程度拉到 0 = 不平滑、只反向。
// - 滚多远：系统给的行数（FixedPt：带着系统设置里「滚动速度」的加速，有小数；一格至少按一行算）× 每行 40 点 × 「滚动距离」。
//   40 点一行是浏览器内核给滚轮定的换算：100% 时在网页里和不平滑时滚得差不多远。
// - 怎么滑（Motion）：每格加进「还没滚完的」，按屏幕刷新一帧帧放出去，每帧放剩下的 1 - e^(-dt/τ)（先快后慢），τ 由「平滑程度」
//   定；剩不到一个点就一次放完、停下。像素只能整数地发，零头攒着下一帧补：放出去的加起来一点不差。
//   往回拨一格把没滚完的扔掉、马上往回走；但紧跟在一串里的单独一格反向当成滚轮抖了一下，不理（Bounce）。
// ponytail: 每行 40 点、一格至少一行是按浏览器内核的换算定的，没拿真鼠标量过系统给的行数（SmoothScrollProbeTests 的
// record() 能量）；量出来不对就改 pointsPerLine 和 lines(_:)。

import Foundation

nonisolated enum ScrollSmoothing {
  /// 设置（主线程读偏好拼好，交给滚动线程；Prefs.smoothScroll*）
  struct Settings: Equatable, Sendable {
    /// 平滑程度 0…100（0 不平滑、只反向；100 滑得最久）
    var strength = 50
    /// 滚动距离（百分比，50…300）
    var speed = 100
    var reverseVertical = false
    var reverseHorizontal = false

    static let strengthRange = 0...100
    static let speedRange = 50...300

    var smooths: Bool { strength > 0 }
    /// 指数逼近的时间常数（秒）：1 → 约 40 ms，50 → 120 ms（约 0.36 秒滑完九成五），100 → 200 ms
    var tau: Double { 0.04 + Double(min(max(strength, 0), 100)) / 100 * 0.16 }
    /// 一行滚多少点
    var pointsPerLine: Double { 40 * Double(min(max(speed, 50), 300)) / 100 }
  }

  /// 一个滚轮事件里要看的几样（从 CGEvent 取成值，纯函数好测）
  struct Wheel: Equatable, Sendable {
    /// 连续的（触控板、妙控鼠标）
    var continuous = false
    /// 带滚动阶段 / 惯性阶段的（触控板的一下）
    var phased = false
    /// 妙控鼠标发的（连续、带阶段，同触控板；按发送设备认）
    var magicMouse = false
    /// 系统给的行数（含系统的加速，有小数；正 = 往上滚 / 往左滚，和 CGEvent 同号）：上下、左右
    var dy = 0.0
    var dx = 0.0
    var option = false
    var shift = false
    /// ⌘ 或 ⌃
    var command = false
  }

  enum Decision: Equatable, Sendable {
    /// 原样放过
    case pass
    /// 不平滑，只把这一个事件的距离反过来（上下、左右哪个要反）
    case flip(vertical: Bool, horizontal: Bool)
    /// 吞掉原事件，把这段距离（点，已经反过向、换过轴）交给 Motion 慢慢放；flipped = 方向被反向那两个开关反过
    /// （合成的帧上「方向已经翻过」的标记要跟着翻，见 ScrollTap.invertedField）
    case smooth(dx: Double, dy: Double, flipped: Bool)
  }

  /// excluded：前台 App 停用了平滑滚动（isExcluded）
  static func decide(_ wheel: Wheel, settings: Settings, excluded: Bool) -> Decision {
    guard !excluded else { return .pass }
    if wheel.continuous || wheel.phased {
      // 妙控鼠标本来就滑着滚：不平滑，只照开关反向（不看距离是不是 0：同一下的每个事件都反，开头才不会倒着动一个点）
      let (flipY, flipX) = (settings.reverseVertical, settings.reverseHorizontal)
      return wheel.magicMouse && (flipY || flipX)
        ? .flip(vertical: flipY, horizontal: flipX) : .pass
    }
    guard wheel.dx != 0 || wheel.dy != 0 else { return .pass }
    // 哪个轴要反：⇧ 按着时拨的还是上下那个滚轮（系统换没换到左右那一轴都一样），跟着「上下反向」
    let flipY = settings.reverseVertical && wheel.dy != 0
    let flipX =
      (wheel.shift ? settings.reverseVertical : settings.reverseHorizontal) && wheel.dx != 0
    if wheel.option || wheel.command || !settings.smooths {
      return flipY || flipX ? .flip(vertical: flipY, horizontal: flipX) : .pass
    }
    var dy = lines(flipY ? -wheel.dy : wheel.dy)
    var dx = lines(flipX ? -wheel.dx : wheel.dx)
    // ⇧：上下滚换成左右滚（系统已经换好了的，左右那一轴本来就有值，不再换）
    if wheel.shift, dx == 0 { (dx, dy) = (dy, 0) }
    let points = settings.pointsPerLine
    return .smooth(dx: dx * points, dy: dy * points, flipped: flipY || flipX)
  }

  /// 这一下不归平滑管（触控板、妙控鼠标、按着修饰键的、平滑程度 0、停用的 App 里的），又是连续的或真有距离：鼠标滑着的
  /// 那一段先停下。触控板一碰就停；按着 ⌘ / ⌃ 缩放时剩下那截不接着滚（issue #37：不然一边缩放一边往下滚）
  static func halts(_ wheel: Wheel, decision: Decision) -> Bool {
    if case .smooth = decision { return false }
    return wheel.continuous || wheel.phased || wheel.dx != 0 || wheel.dy != 0
  }

  /// 一格至少按一行算：系统的加速在慢慢拨时可能给不到一行
  static func lines(_ value: Double) -> Double {
    value == 0 ? 0 : (value < 0 ? -1 : 1) * max(abs(value), 1)
  }

  // MARK: 停用的 App

  /// 自己管滚轮、不该平滑的：虚拟机、远程桌面（一格变成几十个小滚动传过去）。游戏另按 App 的分类认（isGame）
  static let builtInExcluded: Set<String> = [
    "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.UTM",
    "org.virtualbox.app.VirtualBox", "org.virtualbox.app.VirtualBoxVM",
    "com.microsoft.rdc.macos", "com.apple.ScreenSharing", "com.teamviewer.TeamViewer",
    "com.philandro.anydesk", "com.realvnc.vncviewer", "tv.parsec.www",
    "com.moonlight-stream.Moonlight", "com.citrix.receiver.icaviewer.mac",
  ]

  /// App 自己在 Info.plist 里写的分类（LSApplicationCategoryType）是游戏：「游戏」和它下面的各类（…-games）
  static func isGame(category: String?) -> Bool {
    guard let category, category.hasPrefix("public.app-category.") else { return false }
    return category.hasSuffix("games")
  }

  /// 前台 App 停没停用：用户的名单、自带的那几个、游戏
  static func isExcluded(app: String?, category: String?, list: Set<String>) -> Bool {
    if let app, list.contains(app) || builtInExcluded.contains(app) { return true }
    return isGame(category: category)
  }

  // MARK: 别的改滚轮的工具

  /// 认得出的、也会改鼠标滚轮的工具（bundle id；界面上只显示它们自己的名字，不写进文案）：两边一起开会平滑两次、反向两次
  static let otherTools: Set<String> = [
    "com.caldis.Mos", "com.pilotmoon.scroll-reverser", "com.lujjjh.LinearMouse",
    "com.nuebling.mac-mouse-fix.helper", "com.theron.UnnaturalScrollWheels",
    "com.naotanhaocan.BetterMouse",
  ]

  /// 正在运行的 App（bundle id、名字）里属于 otherTools 的那几个的名字
  static func runningOtherTools(_ apps: [(id: String?, name: String?)]) -> [String] {
    apps.compactMap { app in
      guard let id = app.id, otherTools.contains(id) else { return nil }
      return app.name ?? id
    }
  }

  // MARK: 滑

  /// 正在滑的那一段：还没放出去的距离、整数像素的零头
  struct Motion: Equatable, Sendable {
    private(set) var remainingX = 0.0
    private(set) var remainingY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0

    /// 两帧之间最多按多久算（线程被耽搁了一阵，不一下子跳过去）
    static let maxStep = 0.05

    var isIdle: Bool { remainingX == 0 && remainingY == 0 }

    /// 再滚了一格：方向反了的话先把没滚完的扔掉（往下滑着时往上拨一格，马上往上走，不先把下面那截滚完）
    mutating func add(dx: Double, dy: Double) {
      if dy != 0, remainingY != 0, (dy > 0) != (remainingY > 0) { (remainingY, carryY) = (0, 0) }
      if dx != 0, remainingX != 0, (dx > 0) != (remainingX > 0) { (remainingX, carryX) = (0, 0) }
      remainingX += dx
      remainingY += dy
    }

    /// 放一帧：dt 是离上一帧多久（秒），返回这一帧发出去的整数像素（左右、上下）；都是 0 时这一帧不用发
    mutating func step(dt: Double, tau: Double) -> (dx: Int, dy: Int) {
      let elapsed = min(max(dt, 0), Self.maxStep)
      let share = tau > 0 ? 1 - exp(-elapsed / tau) : 1
      let x = Self.take(&remainingX, share: share)
      let y = Self.take(&remainingY, share: share)
      return (
        Self.whole(x, carry: &carryX, last: remainingX == 0),
        Self.whole(y, carry: &carryY, last: remainingY == 0)
      )
    }

    /// 从剩下的里取一份；剩得不到一个点就整个取走
    private static func take(_ remaining: inout Double, share: Double) -> Double {
      guard remaining != 0 else { return 0 }
      if abs(remaining) < 1 {
        defer { remaining = 0 }
        return remaining
      }
      let part = remaining * share
      remaining -= part
      return part
    }

    /// 小数像素攒着：发整数的那部分，零头记下（下一帧补）；这一段放完了（last）就把零头四舍五入一起发掉
    private static func whole(_ value: Double, carry: inout Double, last: Bool) -> Int {
      let total = value + carry
      let rounded = last ? total.rounded() : total.rounded(.towardZero)
      carry = last ? 0 : total - rounded
      return Int(rounded)
    }
  }

  /// 滚轮抖一下（便宜的滚轮在一串里夹一格反向）：离上一格不到 window 秒、和上一格反向的单独一格不理；连着两格反向才算
  /// 真的往回拨（真往回拨也只丢第一格）
  struct Bounce: Equatable, Sendable {
    static let window = 0.05

    private var lastTime = -Double.infinity
    /// 上一格认下的方向：上下 ±1、左右 ±2；0 = 还没有
    private var lastDirection = 0
    /// 上一格是当成抖动扔掉的
    private var suspect = false

    /// 这一格（dx、dy 是要滑的距离，time 是事件的时刻，秒）认不认
    mutating func accept(dx: Double, dy: Double, time: Double) -> Bool {
      defer { lastTime = time }
      let direction = dy != 0 ? (dy > 0 ? 1 : -1) : (dx > 0 ? 2 : -2)
      if lastDirection != 0, direction == -lastDirection, time - lastTime < Self.window, !suspect {
        suspect = true
        return false
      }
      suspect = false
      lastDirection = direction
      return true
    }
  }
}
