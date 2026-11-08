// 截图 / 录屏框选时认指针下的界面元素（2026-11-08 拍板，方案页 https://claude.ai/artifact/2W5EqQuQohfGTvVdk3fEKz ）：
// 冻结时的窗口列表认出指针下是哪个 App 的窗口，只问那个 App「这个点上是什么」（App 级查询：系统级会查到盖在上面的遮罩，
// 实测），再一路往上拿父级的框，过滤、裁剪、去重成从小到大的几层（layers，纯函数）。窗口那一层由调用方接在最后。
// 只在主线程、只在框选时问：实测一次命中测试 0.0–0.3 ms、最慢 13 ms，往上读一串 0.3–2 ms（PLAN §10「截图识别元素」）；
// 指针还在同一个元素上时只做命中测试（Cache）。一次查询一共最多等 timeout，超时（.unresponsive）的 App 这次截图不再问
// （SelectionSession.silentApps）。
// ponytail: 主线程问，卡住或很慢的 App 每次框选最多顿一下 timeout（0.1 s）；真碰到掉帧再挪出主线程（要把「读界面元素」
// 加进 @concurrent 第 3 类）。

import AppKit
import ApplicationServices

enum ElementFinder {
  /// 一次查询（命中测试 + 往上读一串）一共最多等多久：超了就当这个 App 卡住（.unresponsive），这次框选不再问它。
  /// 每个对象各给 0.1 s 的话，一串几十层、每层都慢一点（忙着的 Electron、正在建索引的 Xcode）就能卡住主线程好几秒（评审）。
  /// 实测第一次问一个 App 27–37 ms，之后 0.1–9 ms；慢的 SwiftUI 窗口第一次可能超，那次框选只认它的窗口
  static let timeout: Duration = .milliseconds(100)
  /// 宽或高不到这个（点）的不算一层：单个图标、一行字太碎
  static let minimumSide: CGFloat = 24
  /// 和上一层四边都差不到这个（点）的并成一层（一串套娃的分组）
  static let mergeSlack: CGFloat = 4

  /// 一层：框（和调用方给的点同一套坐标）和系统给的种类名（「按钮」「组」，旁白用；取不到时 nil）
  struct Layer: Equatable {
    var frame: CGRect
    var name: String?
  }

  enum Answer: Equatable {
    /// 从指针下最里面的那个元素往上到窗口，AppKit 全局坐标（原点在主屏左下），没过滤
    case chain([Layer])
    /// 超时：那个 App 卡住了
    case unresponsive
  }

  /// 上一次问到的最里面那个元素和它那一串：指针还在同一个元素上（命中的是同一个）时不再一层层往上读。一次框选一个
  /// （跨框选留着的话，窗口挪过、界面变过，框就旧了）
  final class Cache {
    var hit: AXUIElement?
    var answer: Answer?
  }

  /// 问 pid 那个 App：point（AppKit 全局坐标）上最里面的元素，和它一路往上到窗口的每一层。查不到给空的 chain
  static func query(pid: pid_t, at point: CGPoint, cache: Cache? = nil) -> Answer {
    // 辅助功能的坐标原点在主屏左上、y 向下
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    /// 每一次跨进程调用最多等到总的期限（至少 10 ms）；过了期限 nil
    func budget(_ element: AXUIElement) -> Bool {
      let left = clock.now.duration(to: deadline)
      guard left > .zero else { return false }
      let seconds = Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
      AXUIElementSetMessagingTimeout(element, Float(max(seconds, 0.01)))
      return true
    }
    let app = AXUIElementCreateApplication(pid)
    _ = budget(app)
    var hit: AXUIElement?
    let found = AXUIElementCopyElementAtPosition(
      app, Float(point.x), Float(primaryHeight - point.y), &hit)
    if found == .cannotComplete { return .unresponsive }
    guard found == .success, var element = hit else { return .chain([]) }
    if let cache, let last = cache.hit, let answer = cache.answer, CFEqual(last, element) {
      return answer
    }
    let leaf = element
    // 读到窗口 / App 为止才算一整串：中途读错了（元素没了、App 不答）的半截不进缓存，下次再读
    var complete = true
    let names =
      [
        kAXRoleAttribute, kAXRoleDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXParentAttribute,
      ] as CFArray
    var chain: [Layer] = []
    // 实测最深的（打开了辅助功能的 Electron）一串 37 层；再深的截掉，只少几层大的
    for _ in 0..<48 {
      guard budget(element) else { return .unresponsive }
      var values: CFArray?
      // 一次跨进程拿五样；没有的那样给的是包着错误的 AXValue
      let status = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
      if status == .cannotComplete { return .unresponsive }
      guard status == .success, let list = values as? [AnyObject], list.count == 5 else {
        complete = false
        break
      }
      let role = list[0] as? String
      if role == kAXApplicationRole { break }
      if let origin = value(list[2], .cgPoint, CGPoint.zero),
        let size = value(list[3], .cgSize, CGSize.zero)
      {
        chain.append(
          Layer(
            frame: CGRect(
              x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width,
              height: size.height),
            name: list[1] as? String))
      }
      guard role != kAXWindowRole, CFGetTypeID(list[4]) == AXUIElementGetTypeID() else { break }
      element = list[4] as! AXUIElement  // 上一行认过类型
    }
    if clock.now > deadline { return .unresponsive }
    if complete {
      cache?.hit = leaf
      cache?.answer = .chain(chain)
    }
    return .chain(chain)
  }

  /// 包在 AXValue 里的点 / 尺寸；不是这一种（属性取不到时是错误）给 nil
  private static func value<T>(_ object: AnyObject, _ type: AXValueType, _ empty: T) -> T? {
    guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
    var result = empty
    return AXValueGetValue(object as! AXValue, type, &result) ? result : nil  // 上一行认过类型
  }

  /// 原始的一串（最里面在前、往上到窗口）→ 指针下能选的几层，从小到大，不含窗口那一层。纯函数，配单测：
  /// 每个框先裁进窗口和它所有包住指针的上层（滚动内容报的框比看得见的大：访达侧栏的列表报 767 高、只露出 412）；
  /// 裁完不包住 point、宽或高不到 minimumSide 的不要；和窗口差不到 mergeSlack 的不要（窗口那层调用方接）；
  /// 和上一层差不到 mergeSlack 的并成一层（留外面那个）。chain、point、window 同一套坐标
  static func layers(_ chain: [Layer], at point: CGPoint, in window: CGRect) -> [Layer] {
    var clip = window
    var visible: [Layer] = []
    for layer in chain.reversed() {
      let shown = layer.frame.intersection(clip)
      if shown.isNull { continue }
      // 不包住指针的（报了零宽高、框报错了的）不拿来裁里面的：不然一层报错，下面全被裁没
      if shown.contains(point) { clip = shown }
      visible.append(Layer(frame: shown, name: layer.name))
    }
    var result: [Layer] = []
    for layer in visible.reversed() {
      let frame = layer.frame
      guard frame.contains(point), frame.width >= minimumSide, frame.height >= minimumSide,
        !close(frame, window)
      else { continue }
      if let last = result.last, close(frame, last.frame) {
        result[result.count - 1] = layer
      } else if result.last.map({ frame.contains($0.frame) }) ?? true {
        result.append(layer)
      }
    }
    return result
  }

  /// 四条边都差不到 mergeSlack
  private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < mergeSlack && abs(a.maxX - b.maxX) < mergeSlack
      && abs(a.minY - b.minY) < mergeSlack && abs(a.maxY - b.maxY) < mergeSlack
  }

  /// 换了一串之后，原来停着的那一层（shown）在新的一串（从小到大）里是第几层：同一个框（差不到 mergeSlack）那层；
  /// 没有就取第一个包住它的；都没有就最大那层。纯函数，配单测
  static func position(of shown: CGRect, in frames: [CGRect]) -> Int {
    frames.firstIndex { close($0, shown) } ?? frames.firstIndex { $0.contains(shown) }
      ?? max(0, frames.count - 1)
  }

  /// 滚轮 / 触控板换层：deltaY 是事件的 scrollingDeltaY，inverted 是「自然滚动」反过来了（isDirectionInvertedFromDevice）——
  /// 按手指 / 滚轮的物理方向算，往上大一层；precise = 触控板这类连续的。滚轮一格换一层；触控板攒够 24 点换一层。
  /// 返回这次换几层（1 大一层、-1 小一层、0 不换）和剩下攒着的量。纯函数，配单测
  static func step(deltaY: CGFloat, inverted: Bool, precise: Bool, pending: CGFloat) -> (
    step: Int, pending: CGFloat
  ) {
    let delta = inverted ? -deltaY : deltaY
    guard precise else { return (delta > 0 ? 1 : delta < 0 ? -1 : 0, 0) }
    let total = pending + delta
    guard abs(total) >= 24 else { return (0, total) }
    return (total > 0 ? 1 : -1, 0)
  }
}
