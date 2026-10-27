// 晾衣绳的绳子物理（2026-10-26 用户手测反馈「动画要物理驱动、有引力的那种」；照样机
// `macos/build/research/clothesline-2026-10-26/mockup.html` 里那份 verlet 搬过来，参数一个不改）：
// 绳子是一串质点，verlet 积分 + 重力 + 阻尼 + 距离约束，两端钉死；挂着卡片的那个质点每帧多吃 2.2 倍重力。
// 卡片的角度跟着它两侧质点的连线走（× 0.6），所以**摇摆是绳子带的、不是卡片自己的动画**——挂第二张时第一张会被带着晃。
// 「挂上去」和「取下」也只是给质点一个位移脉冲，波自然沿绳子传开，不另写衰减曲线。
// 全部质点的速度都小于 restSpeed 之后就算停了，调用方停表（Whisker §8：不能有常驻的循环动画）。
// 参数是照 60 Hz 一帧一步调的：调用方按真过去的时间走几步（steps，第三轮体检 P2：掉到 30 Hz 时一帧两步）。
// 纯值类型、nonisolated：配单测（ClotheslineTests），也方便截图自检先跑到静止再出图。

import CoreGraphics
import Foundation

nonisolated struct ClotheslineRope: Equatable {
  /// 一个质点：现在在哪、上一帧在哪（两者之差就是速度，verlet 不另存速度）、钉死没有、挂着多重的东西
  struct Node: Equatable {
    var x: CGFloat
    var y: CGFloat
    var previousX: CGFloat
    var previousY: CGFloat
    var isPinned = false
    /// 挂着的卡片的重量（每帧多吃这么多倍重力；没挂是 0）
    var load: CGFloat = 0

    var point: CGPoint { CGPoint(x: x, y: y) }
    var speed: CGFloat { max(abs(x - previousX), abs(y - previousY)) }
  }

  /// 样机里定下来的参数（滑块拖到满意之后的值）
  static let count = 34
  static let gravity: CGFloat = 0.5
  static let damping: CGFloat = 0.95
  /// 每帧把距离约束迭代几遍（= 绳子有多绷）。样机是 24，2026-10-26 用户说「弧度小一点」之后调到 64：
  /// verlet 的约束是软的，迭代少了重力就把绳子拉得很深——绷紧它比调垂度管用（两样都调了）
  static let iterations = 64
  /// 垂度：绳长比两端直线距离多出来的那一点（`rest` 里的 /900 就是它）。样机是 26，同日按用户要求收到 12
  static let sag: CGFloat = 12
  /// 挂着卡片的质点多吃几倍重力
  static let load: CGFloat = 2.2
  /// 全部质点都慢过这个数就算停了
  static let restSpeed: CGFloat = 0.05
  /// 一步是多久：上面这些参数都是照 60 Hz 一帧一步调的
  static let tick: TimeInterval = 1.0 / 60
  /// 一帧最多补几步（卡了很久之后别一口气算一大串）
  static let maxCatchUp = 4

  /// 这一帧该走几步：按真过去的时间算（30 Hz 时一帧两步——原来一帧一步，掉帧时摆得慢一半），不够一步的零头攒在
  /// carry 里留到下一帧；补不完的（卡了很久）扔掉。纯函数，配单测
  static func steps(for elapsed: TimeInterval, carry: inout TimeInterval) -> Int {
    carry += max(elapsed, 0)
    // 1/30 ÷ 1/60 算出来可能是 1.9999…：差一点点的算够一步，不然两帧一抖
    let steps = Int(carry / tick + 0.001)
    guard steps <= maxCatchUp else {
      carry = 0
      return maxCatchUp
    }
    carry = max(carry - Double(steps) * tick, 0)
    return steps
  }

  private(set) var nodes: [Node]
  /// 两个质点之间该有多长
  private(set) var rest: CGFloat

  /// 两端钉死，初始就带一点自然下垂（正弦，不然第一帧像根直棍突然塌下去）
  init(from start: CGPoint, to end: CGPoint, count: Int = ClotheslineRope.count) {
    let count = max(count, 2)
    nodes = (0..<count).map { index in
      let t = CGFloat(index) / CGFloat(count - 1)
      let x = start.x + (end.x - start.x) * t
      let y = start.y + (end.y - start.y) * t + sin(t * .pi) * Self.sag * 0.9
      return Node(
        x: x, y: y, previousX: x, previousY: y, isPinned: index == 0 || index == count - 1)
    }
    rest = (end.x - start.x) / CGFloat(count - 1) * (1 + Self.sag / 900)
  }

  // MARK: 一帧

  /// 走一帧：先积分、再把距离约束迭代几遍（样机里的 step）
  mutating func step() {
    for index in nodes.indices where !nodes[index].isPinned {
      var node = nodes[index]
      let vx = (node.x - node.previousX) * Self.damping
      let vy = (node.y - node.previousY) * Self.damping
      node.previousX = node.x
      node.previousY = node.y
      node.x += vx
      node.y += vy + Self.gravity + Self.gravity * node.load
      nodes[index] = node
    }
    for _ in 0..<Self.iterations { relax() }
  }

  private mutating func relax() {
    for index in 0..<(nodes.count - 1) {
      let a = nodes[index]
      let b = nodes[index + 1]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
      let share = (distance - rest) / distance * 0.5
      let ox = dx * share
      let oy = dy * share
      if !a.isPinned {
        nodes[index].x = a.x + ox
        nodes[index].y = a.y + oy
      }
      if !b.isPinned {
        nodes[index + 1].x = b.x - ox
        nodes[index + 1].y = b.y - oy
      }
    }
  }

  /// 全都慢下来了（调用方据此停表）
  var isAtRest: Bool { nodes.allSatisfy { $0.speed < Self.restSpeed } }

  /// 跑到静止（截图自检、单测用；最多走 limit 帧）
  mutating func settle(limit: Int = 600) {
    for _ in 0..<limit {
      step()
      if isAtRest { return }
    }
  }

  // MARK: 推一把

  /// 位移脉冲：只挪现在的位置、不动上一帧的，verlet 里这就等于给了一下速度（样机的「抖一抖」和挂上去的那一下都是它）
  mutating func push(_ index: Int, dx: CGFloat = 0, dy: CGFloat) {
    guard nodes.indices.contains(index), !nodes[index].isPinned else { return }
    nodes[index].x += dx
    nodes[index].y += dy
  }

  /// 这个质点挂上 / 取下卡片（挂着的每帧多吃 load 倍重力）
  mutating func setLoaded(_ index: Int, _ loaded: Bool) {
    guard nodes.indices.contains(index) else { return }
    nodes[index].load = loaded ? Self.load : 0
  }

  // MARK: 读

  func point(_ index: Int) -> CGPoint {
    nodes[min(max(index, 0), nodes.count - 1)].point
  }

  /// 卡片的角度：它两侧质点的连线角度 × 0.6（样机：摇摆的来源）
  func angle(at index: Int) -> CGFloat {
    let before = point(index - 1)
    let after = point(index + 1)
    return atan2(after.y - before.y, after.x - before.x) * 0.6
  }

  /// 哪个质点离这个 x 最近（卡片挂在那儿）
  func nearest(x: CGFloat) -> Int {
    nodes.indices.min { abs(nodes[$0].x - x) < abs(nodes[$1].x - x) } ?? 0
  }

  var points: [CGPoint] { nodes.map(\.point) }
}
