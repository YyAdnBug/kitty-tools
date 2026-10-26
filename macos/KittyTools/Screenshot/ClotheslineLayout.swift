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
  /// 卡片之间、离屏幕两边
  static let spacing: CGFloat = 10
  static let sideInset: CGFloat = 16
  /// 绳子离面板顶边（面板顶边贴着菜单栏下沿）
  static let ropeTop: CGFloat = 8
  /// 中间垂下来多少（两端固定的二次贝塞尔，最低点在中点）
  static let sag: CGFloat = 9
  /// 夹子多高：卡片从绳子往下让这么多，夹子正好压在绳子上
  static let clipHeight: CGFloat = 13
  /// 绳子粗细
  static let ropeWidth: CGFloat = 1.5
  /// 中间给刘海岛让出来的那一段至少这么宽（C2）：刘海屏按刘海宽 + 两边各 12
  static let minimumGap: CGFloat = 220
  /// 最多挂几张（B3）
  static let maxCards = 8
  /// 卡片四周给阴影留的余量（面板比卡片高这么多）
  static let shadowMargin: CGFloat = 18
  /// 悬停时右上角那个 ✕（和常驻缩略图的圆钮同样大）和它离卡片边的距离
  static let closeSide: CGFloat = 22
  static let closeInset: CGFloat = 6
  /// 刚挂上去摇一下：从这个角度弹回 0（拍板 D1，用现成的 pop 弹簧，别新造曲线）
  static let swingAngle: Double = -5

  /// 面板多高：绳子 + 下垂 + 夹子 + 卡片 + 阴影余量
  static var panelHeight: CGFloat {
    ropeTop + sag + clipHeight + cardHeight + shadowMargin
  }

  /// 中间断开多宽：刘海那一块两边各多 12，至少 minimumGap
  static func gap(notch: CGRect?) -> CGFloat { max(minimumGap, (notch?.width ?? 0) + 24) }

  /// 绳子的一段：两端 + 控制点（控制点在中点正下方 2 × sag，曲线最低点正好垂 sag）
  struct Rope: Equatable {
    var from: CGPoint
    var to: CGPoint
    var control: CGPoint
  }

  /// 排好的样子：卡片的框和绳子那两段，都是面板内坐标（原点左上，同 SwiftUI）
  struct Plan: Equatable {
    var cards: [CGRect] = []
    var ropes: [Rope] = []
  }

  /// 绳子在 x 处垂下来多少：两端固定、控制点在中点，所以 x 和参数 t 是线性的，y = 4 × sag × t(1 − t)
  static func drop(x: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat {
    guard to > from else { return 0 }
    let t = min(max((x - from) / (to - from), 0), 1)
    return 4 * sag * t * (1 - t)
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
        CGRect(x: minX, y: ropeTop + sagging + clipHeight, width: box, height: cardHeight))
    }
    return plan
  }

  private static func rope(from: CGFloat, to: CGFloat) -> Rope {
    Rope(
      from: CGPoint(x: from, y: ropeTop), to: CGPoint(x: to, y: ropeTop),
      control: CGPoint(x: (from + to) / 2, y: ropeTop + 2 * sag))
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
