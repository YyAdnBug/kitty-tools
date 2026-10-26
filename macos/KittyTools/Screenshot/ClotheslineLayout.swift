// 晾衣绳的几何与时机（第十族，2026-10-26 拍板，macos/build/research/clothesline-2026-10-26/decisions.html；
// 纯函数，配单测 ClotheslineTests）：屏幕顶上一根绳子，截图挂在上面。
// 绳子两端固定在屏幕两边、中间自然下垂（二次贝塞尔），**正中间断开一段**给刘海岛让位（拍板 C2）；
// 卡片一张张从两边往中间挂（第 1 张最左、第 2 张最右、第 3 张挨着第 1 张……），谁都不占中间那一段，
// 所以岛冒出来也不用挪照片。最多 8 张，屏幕窄时按宽度减（B3）。
// 什么时候滑下来 / 收起（C1，和程序坞预览一个脾气）：鼠标停在菜单栏那一条上算要看它（刘海那一块不算——
// 那是刘海岛的），离开面板和那一条满 0.4 秒才收；按鼠标位置算，不用追踪区的进出（面板改尺寸会重建追踪区、
// 淡出时进来的事件会丢，mac-dock-preview §5）。
// nonisolated：绳子的形状在 SwiftUI 的渲染线程上问 path(in:)（mac-native §3），这些几何都不绑主线程。

import AppKit

nonisolated enum ClotheslineLayout {
  /// 卡片的高（宽按原图的比例算，夹在 cardWidths 里）：常驻缩略图的一半出头，一排挂得下 8 张
  static let cardHeight: CGFloat = 92
  static let cardWidths: ClosedRange<CGFloat> = 64...180
  /// 卡片之间、离屏幕两边（两头的卡片跟着绳子斜得最厉害，留宽一点别让角出屏幕）
  static let spacing: CGFloat = 10
  static let sideInset: CGFloat = 44
  /// 两端钉在哪（面板内坐标）：**在面板上沿以上**，所以两头和中间断口那四个端点都藏在菜单栏后面、
  /// 看不见（2026-10-26 用户：「绳子两边的点…期望往上一点，隐藏起来」）。绳子沉得快，离端点十几点就落进
  /// 面板里了，看着就是从菜单栏底下伸出来的一条
  static let ropeTop: CGFloat = -6
  /// 挂满卡片时绳子还会再往下坠一点（每张多吃 2.2 倍重力，量出来最多多一成）：面板按这个倍数留地方
  static let loadedSagRoom: CGFloat = 1.15
  /// 挂点到卡片顶边：绳子从夹子中间穿过去（样机里卡片画在 node.y + 6）
  static let hangDrop: CGFloat = 6
  /// 夹子：两片圆角竖条（各 4.5 × 20、圆角 2、0.9 透明度，中间留 1.5 的缝）+ 中间一道弧当弹簧
  /// （半径 4.6、1.5 pt 描边、0.65 透明度，从 0.15π 到 0.85π）。夹子的中心在卡片顶边上方 4 点（= 挂点下方 2 点）
  static let clipBar = CGSize(width: 4.5, height: 20)
  static let clipGap: CGFloat = 1.5
  static let clipRadius: CGFloat = 2
  static let clipSpringRadius: CGFloat = 4.6
  static let clipSpringWidth: CGFloat = 1.5
  static let clipCenterAboveCard: CGFloat = 4
  /// 夹子整个占多高（排面板高度用）
  static var clipHeight: CGFloat { clipBar.height / 2 + clipCenterAboveCard }
  /// 绳子粗细、墨色的透明度、底下那道影（线宽 +1、往下偏 2.5、black 0.16）。
  /// 两端不画挂点：端点本来就在面板外面，画了也看不见（上面 ropeTop 那条）
  static let ropeWidth: CGFloat = 1.5
  static let ropeInk: Double = 0.55
  static let ropeShadowOffset: CGFloat = 2.5
  static let ropeShadowInk: Double = 0.16
  /// 中间给刘海岛让出来的那一段至少这么宽（C2）：刘海屏按刘海宽 + 两边各 12
  static let minimumGap: CGFloat = 220
  /// 最多挂几张（B3）
  static let maxCards = 8
  /// 卡片四周给阴影留的余量（面板比卡片高这么多）
  static let shadowMargin: CGFloat = 18
  /// 悬停时右上角那个 ✕（和常驻缩略图的圆钮同样大）和它离卡片边的距离
  static let closeSide: CGFloat = 22
  static let closeInset: CGFloat = 6
  /// 挂上去：卡片从挂点上方这么高落下（重力 × dropGravity 加速），碰到绳子那一刻「咬住」。
  /// 样机里是 180，那块画布绳子上面有的是地方；我们的面板上沿就贴着菜单栏、绳子离顶边只有 8 点，
  /// 落得再高也被窗口裁掉（飞行卡片的落点还会跑到屏幕外面去），所以收成 26：卡片从面板顶边那儿落下来
  static let dropHeight: CGFloat = 26
  static let dropGravity: CGFloat = ClotheslineRope.gravity * 1.6
  /// 咬住那一下把挂点压低多少（波自然沿绳子传开，不另写衰减曲线）
  static let catchDip: CGFloat = 6
  /// 取下时给那个质点的释放脉冲（绳子回弹；样机「抖一抖」同一个量级）
  static let releaseImpulse = CGVector(dx: 8, dy: -26)
  /// 取下的卡片往下坠多少、淡出多久
  static let leaveDrop: CGFloat = 60
  static let leaveDuration: Double = 0.22
  /// 卡片最多歪多少（弧度）：绳子两端最陡，不夹住的话最外面那张要歪十几度，看着像要掉下去。
  /// 只夹角度、不动位置，夹子照旧在挂点上
  static let maxTilt: Double = 0.16
  /// 每张卡自己的一点固定小倾角（样机里是随机，这里按编号算：同一张每次都一样，截图自检才稳）
  static let tiltRange: Double = 0.14

  /// 这张卡自己歪多少（弧度）：按编号散开，范围 ±tiltRange / 2
  static func tilt(for id: UUID) -> Double {
    var hash: UInt64 = 0x9E37_79B9_7F4A_7C15
    for byte in withUnsafeBytes(of: id.uuid, Array.init) {
      hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3
    }
    return (Double(hash % 1000) / 1000 - 0.5) * tiltRange
  }

  /// 绳子静止时中间垂多少。**这是量出来的**（`ClotheslineRope` 那套参数跑到静止、取最低点，
  /// 跨度 400 / 646 / 900 / 1292 分别是 50.4 / 66.3 / 86.5 / 116.5 点；2026-10-26 用户说「弧度小一点」，
  /// 垂度 26 → 12、迭代 24 → 64 之后重新量的，原来是 71.7 / 95.8 / 125.2 / 169.3）：verlet 的约束是软的，
  /// 重力会把它拉得比「绳长多出那一截」的几何值更低，所以不去推公式、直接用这条拟合线（跨度很小时按比例封顶）。
  /// 单测 `ropeSettlesIntoASag` 拿真的绳子对着它比：改了物理参数这里要重新量
  static func restSag(span: CGFloat) -> CGFloat {
    guard span > 0 else { return 0 }
    return min(span * 0.074 + 21, span * 0.25)
  }

  /// 面板多高：绳子 + 坠下去 + 挂点到卡片顶边 + 卡片 + 阴影余量。
  /// 按中间只让 minimumGap 算（刘海屏让得更宽、跨度更小、垂得更浅，宽一点的估值兜得住）
  static func panelHeight(width: CGFloat) -> CGFloat {
    let span = max((width - minimumGap) / 2, 1)
    return ropeTop + restSag(span: span) * loadedSagRoom + hangDrop + cardHeight + shadowMargin
  }

  /// 中间断开多宽：刘海那一块两边各多 12，至少 minimumGap
  static func gap(notch: CGRect?) -> CGFloat { max(minimumGap, (notch?.width ?? 0) + 24) }

  /// 绳子的一段：两端 + 控制点（控制点在中点正下方 2 × sag，曲线最低点正好垂 sag）
  struct Rope: Equatable {
    var from: CGPoint
    var to: CGPoint
    var control: CGPoint
  }

  /// 排好的样子：卡片静止时的框和绳子那两段（面板内坐标，原点左上，同 SwiftUI）。
  /// 真跑起来时卡片的位置和角度由绳子的物理给（ClotheslineRope），这里只管：挂在哪个 x、多宽、
  /// 飞行卡片的落点、减弱动态效果时画成什么样
  struct Plan: Equatable {
    var cards: [CGRect] = []
    var ropes: [Rope] = []
  }

  /// 绳子在 x 处垂下来多少：两端固定、控制点在中点，所以 x 和参数 t 是线性的，y = 4 × 垂度 × t(1 − t)
  static func drop(x: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
    guard to > from else { return 0 }
    let t = min(max((x - from) / (to - from), 0), 1)
    return 4 * restSag(span: to - from) * t * (1 - t)
  }

  /// 一张卡片多宽：按原图的比例，夹在 cardWidths 里（长截图这种细长的不会把绳子占满）
  static func width(of pixels: CGSize) -> CGFloat {
    guard pixels.width > 0, pixels.height > 0 else { return cardHeight }
    let ideal = cardHeight * pixels.width / pixels.height
    return min(max(ideal.rounded(), cardWidths.lowerBound), cardWidths.upperBound)
  }

  /// 排法（B3 C2）：sizes 是挂着的那几张原图的像素尺寸，挂上的先后排在前面。
  /// 第 1 张挂最左、第 2 张挂最右、第 3 张挨着第 1 张……中间那一段留给刘海岛；选中的那一边放不下了就挂另一边，
  /// 两边都放不下的不挂（屏幕窄时挂得少，调用方据此知道该把最旧的取下来）
  static func plan(_ sizes: [CGSize], width: CGFloat, gap: CGFloat) -> Plan {
    var plan = Plan()
    let half = ((width - gap) / 2).rounded()
    guard half > sideInset else { return plan }
    plan.ropes = [
      rope(from: 0, to: half),
      rope(from: width - half, to: width),
    ]
    // 两边各一个游标：左边从左往右，右边从右往左
    var cursors = [sideInset, width - sideInset]
    let limits = [half, width - half]
    for (index, size) in sizes.prefix(maxCards).enumerated() {
      let box = Self.width(of: size)
      // 先试该它的那一边，放不下再试另一边
      let sides = index.isMultiple(of: 2) ? [0, 1] : [1, 0]
      guard
        let side = sides.first(where: { side in
          side == 0 ? cursors[0] + box <= limits[0] : cursors[1] - box >= limits[1]
        })
      else { continue }
      let minX = side == 0 ? cursors[side] : cursors[side] - box
      cursors[side] += side == 0 ? box + spacing : -(box + spacing)
      let sagging = Self.drop(
        x: minX + box / 2, from: plan.ropes[side].from.x, to: plan.ropes[side].to.x)
      plan.cards.append(
        CGRect(x: minX, y: ropeTop + sagging + hangDrop, width: box, height: cardHeight))
    }
    return plan
  }

  private static func rope(from: CGFloat, to: CGFloat) -> Rope {
    Rope(
      from: CGPoint(x: from, y: ropeTop), to: CGPoint(x: to, y: ropeTop),
      control: CGPoint(x: (from + to) / 2, y: ropeTop + 2 * restSag(span: to - from)))
  }

  /// 一块屏上这几张能挂下几张（挂不下的调用方把最旧的取下来，B3）
  static func fits(_ sizes: [CGSize], width: CGFloat, gap: CGFloat) -> Int {
    plan(sizes, width: width, gap: gap).cards.count
  }

  // MARK: 什么时候滑下来

  /// 面板的上沿：菜单栏下面。**菜单栏自动隐藏时 visible 顶到屏幕顶边**，这时按菜单栏的高往下让——
  /// 面板在状态栏层级（比菜单栏高），贴着屏幕顶边摆的话，鼠标顶上去菜单栏露出来就被它盖住了
  static func top(screen: CGRect, visible: CGRect, menuBar: CGFloat) -> CGFloat {
    min(visible.maxY, screen.maxY - menuBar)
  }

  /// 鼠标停在哪一条上才滑下来：面板上沿到屏幕顶边那一条，也就是菜单栏（自动隐藏时是它让出来的那一条）
  static func strip(screen: CGRect, visible: CGRect, menuBar: CGFloat) -> CGRect {
    let top = top(screen: screen, visible: visible, menuBar: menuBar)
    return CGRect(x: screen.minX, y: top, width: screen.width, height: max(screen.maxY - top, 1))
  }

  /// 该滑下来吗：鼠标在那一条上，而且不在刘海上——刘海是刘海岛的（点它是叫那一张出来，mac-whisker §5 S2）
  static func wantsShow(mouse: CGPoint, strip: CGRect, notch: CGRect?) -> Bool {
    guard NSMouseInRect(mouse, strip, false) else { return false }
    return !(notch.map { NSMouseInRect(mouse, $0, false) } ?? false)
  }

  /// 还算不算在绳子这儿（滑下来之后按鼠标位置决定收不收）：在面板上（外扩 4 点）、或者还在菜单栏那一条上。
  /// 面板紧贴在那一条下面，所以不用像程序坞预览那样再架一座桥
  static func keepsOpen(mouse: CGPoint, panel: CGRect, strip: CGRect) -> Bool {
    NSMouseInRect(mouse, panel.insetBy(dx: -4, dy: -4), false) || NSMouseInRect(mouse, strip, false)
  }

  /// 鼠标离开之后的倒计时：离开满 delay 秒才收，回来就重新算（C1 是 0.4 秒）。
  /// 程序坞预览那边有一份同样的（DockPreviewLayout.Linger，0.3 秒）：两族各管各的时机，不互相依赖
  struct Linger: Equatable {
    static let delay: TimeInterval = 0.4
    private(set) var leftAt: TimeInterval?

    /// 这一刻在不在这儿；返回 true = 该收了
    mutating func update(inside: Bool, now: TimeInterval) -> Bool {
      guard !inside else {
        leftAt = nil
        return false
      }
      guard let leftAt else {
        self.leftAt = now
        return false
      }
      return now - leftAt >= Self.delay
    }
  }

  /// 停多久才滑下来（C1）
  static let showDelay: Duration = .milliseconds(300)
  /// 挂上去之后至少亮这么久（看得见它落在哪），之后鼠标不在上面就照常收
  static let pegHold: Duration = .milliseconds(2500)
  /// 看鼠标在哪的间隔（同程序坞预览）
  static let watchInterval: TimeInterval = 0.1
}
