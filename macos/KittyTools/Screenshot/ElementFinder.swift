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
  /// 宽或高不到这个（点）的不算一层：单个小图标、一行字太碎。菜单栏右边的图标（Wi‑Fi、时钟）高 22，要算（拍板时是 24）
  static let minimumSide: CGFloat = 20
  /// 和上一层四边都差不到这个（点）的并成一层（一串套娃的分组）
  static let mergeSlack: CGFloat = 4
  /// 从命中的元素往下钻最多几层、一共读几个子元素（见 query）
  static let depthLimit = 8
  static let visitLimit = 48

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

  /// 每个进程上一次问的结果，下一次还是同一个命中元素、而且结果不会变时直接用（菜单栏一个点要问前台 App 和控制中心两家，
  /// 按进程分开存，不然两家来回顶掉）。一次框选一个（跨框选留着的话，窗口挪过、界面变过，框就旧了）
  final class Cache {
    struct Entry {
      /// 命中测试给的那个元素
      let hit: AXUIElement
      let answer: Answer
      /// 往下钻到的最里面那块：指针还在它里面，钻的结果不变。没钻下去时 nil
      let within: CGRect?
      /// 命中元素第一层子元素的框：没钻下去时，指针进了其中一个就得重钻
      let children: [CGRect]

      func holds(_ point: CGPoint) -> Bool {
        within.map { $0.contains(point) } ?? !children.contains { $0.contains(point) }
      }
    }
    var entries: [pid_t: Entry] = [:]
  }

  /// 一次读五样：种类、种类名、位置、大小、父级（没有的那样给的是包着错误的 AXValue）
  private static let names =
    [
      kAXRoleAttribute, kAXRoleDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute,
      kAXParentAttribute,
    ] as CFArray

  /// 问 pid 那个 App：point（AppKit 全局坐标）上最里面的元素，和它一路往上到窗口的每一层。查不到给空的 chain
  static func query(pid: pid_t, at point: CGPoint, cache: Cache? = nil) -> Answer {
    // 辅助功能的坐标原点在主屏左上、y 向下
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    /// 下一次跨进程调用最多等到 limit（至少 10 ms）；过了 limit false
    func budget(_ element: AXUIElement, until limit: ContinuousClock.Instant) -> Bool {
      let left = clock.now.duration(to: limit)
      guard left > .zero else { return false }
      AXUIElementSetMessagingTimeout(element, max(seconds(left), 0.01))
      return true
    }
    /// 一个元素的种类名、框（AppKit 全局坐标）、种类和父级；读的结果
    func read(_ element: AXUIElement) -> (
      layer: Layer?, role: String?, parent: AXUIElement?, AXError
    ) {
      var values: CFArray?
      let status = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
      guard status == .success, let list = values as? [AnyObject], list.count == 5 else {
        return (nil, nil, nil, status == .success ? .failure : status)
      }
      var layer: Layer?
      if let origin = value(list[2], .cgPoint, CGPoint.zero),
        let size = value(list[3], .cgSize, CGSize.zero)
      {
        layer = Layer(
          frame: CGRect(
            x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width,
            height: size.height),
          name: list[1] as? String)
      }
      let parent =
        CFGetTypeID(list[4]) == AXUIElementGetTypeID() ? (list[4] as! AXUIElement) : nil  // 认过类型
      return (layer, list[0] as? String, parent, .success)
    }

    let app = AXUIElementCreateApplication(pid)
    _ = budget(app, until: deadline)
    var hit: AXUIElement?
    let found = AXUIElementCopyElementAtPosition(
      app, Float(point.x), Float(primaryHeight - point.y), &hit)
    if found == .cannotComplete { return .unresponsive }
    guard found == .success, let hit else { return .chain([]) }
    if let entry = cache?.entries[pid], CFEqual(entry.hit, hit), entry.holds(point) {
      return entry.answer
    }

    // 命中的是个大容器时往下钻（访达的列表视图给整个滚动区、SwiftUI 给整页：命中测试是各 App 自己答的）：只进框包住
    // 指针的子元素，取面积最小的，可见的子元素优先；最多 depthLimit 层、读 visitLimit 个、花 timeout 的一半，到了就停在
    // 钻到的那层（不算卡住，这一层已经找到的也算上）。照开源的 macshot（deepestAccessibilityRect）
    var inner: [Layer] = []
    var children: [CGRect] = []
    var node = hit
    var visited = 0
    let limit = clock.now + timeout / 2
    for depth in 0..<depthLimit {
      guard budget(node, until: limit) else { break }
      var list: CFArray?
      var status = AXUIElementCopyAttributeValues(
        node, "AXVisibleChildren" as CFString, 0, 64, &list)
      if status == .cannotComplete { break }
      if status != .success || (list as? [AXUIElement])?.isEmpty != false {
        guard budget(node, until: limit) else { break }
        status = AXUIElementCopyAttributeValues(
          node, kAXChildrenAttribute as CFString, 0, 64, &list)
      }
      guard status == .success, let kids = list as? [AXUIElement], !kids.isEmpty else { break }
      var best: (element: AXUIElement, layer: Layer)?
      var stop = false
      for kid in kids {
        visited += 1
        guard visited <= visitLimit, budget(kid, until: limit) else {
          stop = true
          break
        }
        let result = read(kid)
        if result.3 == .cannotComplete {
          stop = true
          break
        }
        guard let layer = result.layer else { continue }
        if depth == 0 { children.append(layer.frame) }
        let area = layer.frame.width * layer.frame.height
        guard layer.frame.contains(point),
          area < (best.map { $0.layer.frame.width * $0.layer.frame.height } ?? .infinity)
        else { continue }
        best = (kid, layer)
      }
      if let best {
        inner.insert(best.layer, at: 0)
        node = best.element
      }
      if stop || best == nil { break }
    }

    // 再一路往上读到窗口。读到窗口 / App 为止才算一整串：中途读错了（元素没了、App 不答）的半截不进缓存，下次再读
    var chain = inner
    var complete = true
    var element = hit
    // 实测最深的（打开了辅助功能的 Electron）一串 37 层；再深的截掉，只少几层大的
    for _ in 0..<48 {
      guard budget(element, until: deadline) else { return .unresponsive }
      let result = read(element)
      if result.3 == .cannotComplete { return .unresponsive }
      guard result.3 == .success else {
        complete = false
        break
      }
      if result.role == kAXApplicationRole { break }
      if let layer = result.layer { chain.append(layer) }
      guard result.role != kAXWindowRole, let parent = result.parent else { break }
      element = parent
    }
    if clock.now > deadline { return .unresponsive }
    if complete {
      cache?.entries[pid] = Cache.Entry(
        hit: hit, answer: .chain(chain), within: inner.first?.frame, children: children)
    }
    return .chain(chain)
  }

  /// 程序坞那一条（AppKit 全局坐标，2026-11-08 用户：程序坞和菜单栏截不到）：窗口列表里程序坞是一扇盖满整屏的透明窗口，
  /// 悬停用不上；读程序坞进程的第一个 AXList（图标那一条，里面的图标是 AXDockItem，悬停时照常问）。自动隐藏时（那一条的
  /// 中心落在屏幕的可用区里：可用区没给它留地方）不算，冻结时多半看不见。要辅助功能授权；读不到 nil。
  /// 两次跨进程调用，各最多等 timeout 的一半（第一次问程序坞约 40 ms，之后约 1 ms，实测）
  static func dockBar() -> ScreenCapture.Window? {
    guard
      let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        .first
    else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(app, seconds(timeout / 2))
    var children: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
      let list = (children as? [AXUIElement])?.first
    else { return nil }
    AXUIElementSetMessagingTimeout(list, seconds(timeout / 2))
    var values: CFArray?
    let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
    guard AXUIElementCopyMultipleAttributeValues(list, names, [], &values) == .success,
      let items = values as? [AnyObject], items.count == 3, items[0] as? String == kAXListRole,
      let origin = value(items[1], .cgPoint, CGPoint.zero),
      let size = value(items[2], .cgSize, CGSize.zero)
    else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let frame = CGRect(
      x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width,
      height: size.height)
    guard ScreenCapture.isReserved(frame) else { return nil }
    return ScreenCapture.Window(
      frame: frame, pids: [dock.processIdentifier], layer: Int(CGWindowLevelForKey(.dockWindow)))
  }

  /// Duration → 秒（辅助功能的超时要 Float 秒）
  private static func seconds(_ duration: Duration) -> Float {
    Float(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
  }

  /// 包在 AXValue 里的点 / 尺寸；不是这一种（属性取不到时是错误）给 nil
  private static func value<T: BitwiseCopyable>(
    _ object: AnyObject, _ type: AXValueType, _ empty: T
  ) -> T? {
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
