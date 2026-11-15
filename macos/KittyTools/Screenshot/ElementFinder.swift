// 截图 / 录屏框选时认指针下的界面元素（2026-11-08 拍板，方案页 https://claude.ai/artifact/2W5EqQuQohfGTvVdk3fEKz ）：
// 冻结时的窗口列表认出指针下是哪个 App 的窗口，只问那个 App「这个点上是什么」（App 级查询：系统级会查到盖在上面的遮罩，
// 实测），再一路往上拿父级的框，过滤、裁剪、去重成从小到大的几层（layers，纯函数）。窗口那一层由调用方接在最后。
// 只在主线程、只在框选时问：实测一次命中测试 0.0–0.3 ms、最慢 13 ms，往上读一串 0.3–2 ms（PLAN §10「截图识别元素」）；
// 指针还在同一个元素上时只做命中测试（Cache）。一次查询一共最多等 timeout，超时（.unresponsive）的 App 这次截图不再问
// （SelectionSession.silentApps）。
// 第三轮（2026-11-15，方案页 https://claude.ai/artifact/Nxzsp9Nssftomsw8FVjn96 ，实测在 macos/build/research/element-detect-v2/）：
// 一层的下限 20 → 16 点；缓存要看指针进没进钻到那块的子元素；指针在窗口工具栏上、命中的却是铺到玻璃工具栏底下的内容
// （macOS 26 起）时改从工具栏往下钻；设置里开了「也认网页里的元素」时先读一次 App 的角色，把浏览器内核叫醒（B1）。
// ponytail: 主线程问，卡住或很慢的 App 每次框选最多顿一下 timeout（0.1 s）；真碰到掉帧再挪出主线程（要把「读界面元素」
// 加进 @concurrent 第 3 类）。

import AppKit
import ApplicationServices

enum ElementFinder {
  /// 一次查询（命中测试 + 往上读一串）一共最多等多久：超了就当这个 App 卡住（.unresponsive），这次框选不再问它。
  /// 每个对象各给 0.1 s 的话，一串几十层、每层都慢一点（忙着的 Electron、正在建索引的 Xcode）就能卡住主线程好几秒（评审）。
  /// 实测第一次问一个 App 27–37 ms，之后 0.1–9 ms；慢的 SwiftUI 窗口第一次可能超，那次框选只认它的窗口
  static let timeout: Duration = .milliseconds(100)
  /// 宽或高不到 minimumSide、或者长边不到 longSide（点）的不算一层：单个小图标、一行字太碎。文件名框（122×18）、
  /// 链接（64×19）、开关（36×16）要算；工具栏按钮 28×28 里那个 16×16 的图、列表里文件名前的 16×16 图标不单算一层
  /// （拍板时是 24，第一轮 20，第三轮 2026-11-15 改成这两个数）
  static let minimumSide: CGFloat = 16
  static let longSide: CGFloat = 20
  /// 只在窗口顶上这一条（点）里找工具栏（工具栏优先，见 query）：macOS 26 起的工具栏高 52，带标签栏的再高些；
  /// 别处不读窗口的子元素（第一次读要串行读到 32 个，吃总时限）
  static let toolbarBand: CGFloat = 120
  /// 叫醒以后指针停着不动、还只认到很粗的一块时，到这几个时刻各再问一次（也认网页里的元素，见 query）：实测 Obsidian
  /// 读完 App 的角色 0.26 s、Claude 约 0.3 s 后命中测试就给细的了；大网页建树慢，1.2 s 再补一次
  static let settles: [Duration] = [.milliseconds(400), .milliseconds(1200)]
  /// 叫醒后这么久里问超时的不记成卡住（SelectionSession.silentApps）：浏览器内核刚开始建网页那棵树，可能一时答得慢
  static let wakeGrace: Duration = .milliseconds(1500)
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
      /// 往下钻到的最里面那块：指针出了它就得重钻。没钻下去时 nil（命中测试还给同一个元素，指针就还在它里面）
      let within: CGRect?
      /// 指针进了其中一个就得重问：钻到的最里面那块（没钻下去时是命中的元素）的子元素（要钻得更深；只记读到了的，
      /// 钻到一半到了上限就是空的或不全。第三轮：只看 within 的话，系统设置里 5% 的点停在大一层），和这扇窗口的
      /// 工具栏（答的不是工具栏时：内容铺到工具栏底下，命中测试还给同一个元素）
      let children: [CGRect]

      /// 纯函数，配单测
      func holds(_ point: CGPoint) -> Bool {
        (within.map { $0.contains(point) } ?? true) && !children.contains { $0.contains(point) }
      }
    }
    var entries: [pid_t: Entry] = [:]
    /// 也认网页里的元素（SelectionSession.wakesWebContent）：每个进程第一次问之前读一次 App 对象的角色（见 query）
    var wakes = false
    /// 叫醒过的进程和叫醒的时刻（到点再问一次用，SelectionSession.recheckDelay）
    var woken: [pid_t: ContinuousClock.Instant] = [:]
    /// 每扇窗口的工具栏（没有 nil）：一扇窗口只读一次，读不清的不记（见 query 的「工具栏优先」）
    var toolbars: [(window: AXUIElement, toolbar: (element: AXUIElement, layer: Layer)?)] = []
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

    /// 这扇窗口的工具栏（直接挂在窗口下、角色是工具栏的那个）。有缓存时一扇窗口只读一次；读不清（超时、读坏）的不记
    func toolbar(of window: AXUIElement) -> Toolbar {
      if let known = cache?.toolbars.first(where: { CFEqual($0.window, window) }) {
        return known.toolbar.map { .found($0.element, $0.layer) } ?? .absent
      }
      guard budget(window, until: deadline) else { return .unknown }
      var list: CFArray?
      let status = AXUIElementCopyAttributeValues(
        window, kAXChildrenAttribute as CFString, 0, 32, &list)
      if status == .cannotComplete { return .unknown }
      var found: (element: AXUIElement, layer: Layer)?
      for kid in status == .success ? (list as? [AXUIElement]) ?? [] : [] {
        guard budget(kid, until: deadline) else { return .unknown }
        let result = read(kid)
        if result.3 == .cannotComplete { return .unknown }
        guard result.role == kAXToolbarRole, let layer = result.layer else { continue }
        found = (kid, layer)
        break
      }
      cache?.toolbars.append((window, found))
      return found.map { .found($0.element, $0.layer) } ?? .absent
    }

    /// 从 start 往下钻（命中的是个大容器时：访达的列表视图给整个滚动区、SwiftUI 给整页，命中测试是各 App 自己答的）：
    /// 只进框包住指针的子元素，取面积最小的，可见的子元素优先；最多 depthLimit 层、读 visitLimit 个、花 timeout 的一半，
    /// 到了就停在钻到的那层（不算卡住，这一层已经找到的也算上）。照开源的 macshot（deepestAccessibilityRect）。
    /// 给钻到的几层（最里面在前）和钻到的最里面那块的子元素里读到的框（缓存用：指针进了其中一个就得重钻）
    func drill(from start: AXUIElement) -> (inner: [Layer], deepest: [CGRect]) {
      var inner: [Layer] = []
      var deepest: [CGRect] = []
      var node = start
      var visited = 0
      let limit = min(clock.now + timeout / 2, deadline)
      for _ in 0..<depthLimit {
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
        var frames: [CGRect] = []
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
          frames.append(layer.frame)
          let area = layer.frame.width * layer.frame.height
          guard layer.frame.contains(point),
            area < (best.map { $0.layer.frame.width * $0.layer.frame.height } ?? .infinity)
          else { continue }
          best = (kid, layer)
        }
        // 钻进了下一层：它的子元素还没读（下一圈读；到了上限就空着，缓存只看 within）
        deepest = best == nil ? frames : []
        if let best {
          inner.insert(best.layer, at: 0)
          node = best.element
        }
        if stop || best == nil { break }
      }
      return (inner, deepest)
    }

    let app = AXUIElementCreateApplication(pid)
    _ = budget(app, until: deadline)
    // 也认网页里的元素（第三轮 B1）：浏览器内核（Chromium、Electron）不主动交出网页里的元素，外部程序读一次 App 对象的
    // 角色才打开最轻的一档辅助功能（只有角色、名字、位置；一直开到它退出），约 0.3 s 后命中测试才给细的（实测 Obsidian
    // 0.26 s，之前 99% 的点只认到窗口、之后 95% 认得出）。不设任何属性：AXManualAccessibility / AXEnhancedUserInterface
    // 开的是最重的读屏那一档，还要截完撤回（拍板 B2 不做）。别的 App 读了也没事；每个进程一次框选只读一次
    if let cache, cache.wakes, cache.woken[pid] == nil {
      cache.woken[pid] = clock.now
      var role: CFTypeRef?
      if AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role) == .cannotComplete
      {
        return .unresponsive
      }
      // 读角色用掉的时间也算在总时限里：命中测试按剩下的设超时
      guard budget(app, until: deadline) else { return .unresponsive }
    }
    var hit: AXUIElement?
    let found = AXUIElementCopyElementAtPosition(
      app, Float(point.x), Float(primaryHeight - point.y), &hit)
    if found == .cannotComplete { return .unresponsive }
    guard found == .success, let hit else { return .chain([]) }
    if let entry = cache?.entries[pid], CFEqual(entry.hit, hit), entry.holds(point) {
      return entry.answer
    }

    // 先一路往上读到窗口（工具栏优先要先知道是哪扇窗口）。读到窗口 / App 为止才算一整串：中途读错了（元素没了、
    // App 不答）的半截不进缓存，下次再读
    var outer: [Layer] = []
    var ancestors: [AXUIElement] = []
    var window: (element: AXUIElement, layer: Layer?)?
    /// 指针在表单、弹出框、菜单里：它们盖在工具栏上面是真的，不换成工具栏
    var floating = false
    var complete = true
    /// 命中的元素自己的框；是窗口本身时 nil
    var hitFrame: CGRect?
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
      if let layer = result.layer { outer.append(layer) }
      if ancestors.isEmpty, result.role != kAXWindowRole { hitFrame = result.layer?.frame ?? .null }
      ancestors.append(element)
      if [kAXSheetRole, kAXDrawerRole, kAXMenuRole, "AXPopover"].contains(result.role) {
        floating = true
      }
      if result.role == kAXWindowRole {
        window = (element, result.layer)
        break
      }
      guard let parent = result.parent else { break }
      element = parent
    }
    // 一串读完了才算超没超时：往下钻到了时限只是停在钻到的那层，不算这个 App 卡住
    if clock.now > deadline { return .unresponsive }

    // 工具栏优先（第三轮）：macOS 26 起内容铺到玻璃工具栏底下，指针停在工具栏按钮上时，访达、本 App 的设置窗这些
    // 命中测试给的是底下被盖住的那一行（访达 4–15% 的点）。指针在这扇窗口顶上那一条（toolbarBand）、在它的工具栏里、
    // 往上那一串又不经过工具栏时，先从工具栏往下钻：钻到了工具栏里的东西（按钮、搜索框），或者命中的元素伸出了工具栏
    // （铺在底下的滚动区、侧栏）、就是窗口本身（underneath），那一串换成「钻到的、工具栏、窗口」。窗口标题那行字直接
    // 挂在窗口下、整个在工具栏那一条里，不是工具栏的东西，不换。认不出工具栏的照旧
    let band = window?.layer.map {
      CGRect(
        x: $0.frame.minX, y: $0.frame.maxY - toolbarBand, width: $0.frame.width,
        height: toolbarBand)
    }
    var bar: (element: AXUIElement, layer: Layer)?
    var looked = false
    var redirected = false
    var inner: [Layer] = []
    var deepest: [CGRect] = []
    if let window, !floating, let band, band.contains(point) {
      looked = true
      switch toolbar(of: window.element) {
      case .unknown: complete = false
      case .absent: break
      case .found(let element, let layer):
        bar = (element, layer)
        if layer.frame.contains(point), !ancestors.contains(where: { CFEqual($0, element) }) {
          let fromBar = drill(from: element)
          if !fromBar.inner.isEmpty || underneath(hitFrame, layer.frame) {
            redirected = true
            (inner, deepest) = fromBar
            outer = [layer] + (window.layer.map { [$0] } ?? [])
          }
        }
      }
    }
    if !redirected { (inner, deepest) = drill(from: hit) }

    let chain = inner + outer
    if complete {
      // 换成工具栏的：指针出了工具栏就得重问（命中测试给的还是底下那个元素）。没换的：指针进了工具栏也得重问；
      // 没找过工具栏的（指针不在顶上那一条里），进了那一条就重问
      var exits = deepest
      if !redirected {
        if let bar, !bar.layer.frame.contains(point) {
          exits.append(bar.layer.frame)
        } else if !looked, let band {
          exits.append(band)
        }
      }
      cache?.entries[pid] = Cache.Entry(
        hit: hit, answer: .chain(chain),
        within: inner.first?.frame ?? (redirected ? bar?.layer.frame : nil), children: exits)
    }
    return .chain(chain)
  }

  /// 叫醒后指针停着不动，离下一个该再问的时刻（settles）还差多久（woken 是叫醒的时刻）；都过了 nil。纯函数，配单测
  static func recheckDelay(wokenAt woken: ContinuousClock.Instant, now: ContinuousClock.Instant)
    -> Duration?
  {
    let elapsed = woken.duration(to: now)
    return settles.first { $0 > elapsed }.map { $0 - elapsed }
  }

  /// 一扇窗口的工具栏：找到了 / 没有 / 这次读不清（超时、读坏：不记进缓存，这次的结果也不进缓存）
  enum Toolbar {
    case found(AXUIElement, Layer)
    case absent
    case unknown
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

  /// 工具栏优先的判断（纯函数，配单测）：命中的元素（hit 是它的框，命中的是窗口本身时 nil）是不是铺在工具栏底下的
  /// 内容——伸出了工具栏（差不到 mergeSlack 的不算伸出）、或者就是窗口。整个在工具栏那一条里的（窗口标题那行字）不算；
  /// 读不出框的（.null）当成伸出去了
  static func underneath(_ hit: CGRect?, _ toolbar: CGRect) -> Bool {
    guard let hit, !hit.isNull else { return true }
    return !toolbar.insetBy(dx: -mergeSlack, dy: -mergeSlack).contains(hit)
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
  /// 裁完不包住 point、宽或高不到 minimumSide、长边不到 longSide 的不要；和窗口差不到 mergeSlack 的不要（窗口那层调用方接）；
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
        max(frame.width, frame.height) >= longSide, !close(frame, window)
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
