// 浮动便签的几何和记下的东西（PLAN §10「便签」第 4 批；窗口的规矩在 mac-overlay-panel §12「浮动便签」）。
// 全是纯函数，单测 NoteFloatTests 锁住：
// - 拖出来：按着把手挪过多远算脱出（detaches）、没挪开算点了一下（moved）、脱出那一刻浮动面板摆在哪（lifted：
//   带着标签的那一侧的上角不动，把手不跳）、之后怎么跟着鼠标走（origin）；
// - 落下、屏幕变了：算在哪块屏（home）、整块夹进那块屏的可见区（clamped / settled）；
// - 不靠拖浮出来时摆在哪（placed）、收回时替身朝哪边滑多远（tuckOffset）；
// - 哪些便签能浮着（floats；层级不在这里：浮动便签一律浮动层级，NoteFloatPanel）；
// - 记下的大小（size：夹进要出现的那块屏）、固定着的那一张的位置（Place：哪条便签 + 在哪；place 定该不该记，
//   restored 定重启后要不要让它回来、回到哪）。
// 数值里脱出的阈值 40、便签最窄 280 起借自 Noty（MIT；只借数值和思路，mac-whisker §11），最小尺寸按我们的头部和
// 操作菜单重算过。

import AppKit

nonisolated enum NoteFloatLayout {
  /// 按着把手往外拖，挪过这么远（哪个方向都算）才脱出来；以内松手 = 没拖
  static let detachDistance: CGFloat = 40
  /// 浮动便签最小多大（连它带着的那张标签）：宽要放得下 260 宽的操作菜单（标签列最宽 38 那一档也够），高要露得出
  /// 头部、五六行正文和底下那行小字
  static let minSize = CGSize(width: 320, height: 220)
  /// 不靠拖浮出来的：比它在那叠里的位置再往屏幕里面挪这么多（看得出它离开了那一列）
  static let floatInset: CGFloat = 48
  /// 收回边缘时朝那条边滑多远（边滑边淡；屏幕边缘没有那叠时不滑）
  static let tuckSlide: CGFloat = 48

  // MARK: 拖出来

  /// 按着把手从 start 挪到 point（全局坐标）：脱没脱出来
  static func detaches(from start: CGPoint, to point: CGPoint) -> Bool {
    hypot(point.x - start.x, point.y - start.y) >= detachDistance
  }

  /// 挪没挪开（没挪开就松手 = 点了一下；和标签拖动排序同一个量 NoteDeckLayout.dragSlop）
  static func moved(from start: CGPoint, to point: CGPoint) -> Bool {
    hypot(point.x - start.x, point.y - start.y) > NoteDeckLayout.dragSlop
  }

  /// 脱出那一刻浮动面板摆在哪（全局坐标）。sheet 是这条便签在那叠里的位置：带着标签的那一侧的上角不动——把手就在
  /// 那一侧和顶上，纸不在手底下跳；大小换成 size（记下的那个。没记过就是它在那叠里的大小，一点都不跳）
  static func lifted(sheet: CGRect, size: CGSize, tabOnLeading: Bool) -> CGRect {
    CGRect(
      x: tabOnLeading ? sheet.minX : sheet.maxX - size.width, y: sheet.maxY - size.height,
      width: size.width, height: size.height)
  }

  /// 跟着鼠标走：grab 是鼠标离面板左下角多远（开始拖的那一刻量的），给出面板的左下角
  static func origin(grab: CGSize, pointer: CGPoint) -> CGPoint {
    CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height)
  }

  // MARK: 落下、屏幕变了

  /// 这块面板算在哪块屏上：给了鼠标（松手的地方）就是鼠标所在的那块，否则是和它重叠最多的那块；哪块都不沾
  /// （原来那块屏拔了）就是第一块（主显示器）。一块屏都没有是 nil
  static func home(of frame: CGRect, pointer: CGPoint? = nil, in screens: [NoteDeckScreen]) -> Int?
  {
    guard !screens.isEmpty else { return nil }
    if let pointer, let under = screens.firstIndex(where: { $0.frame.contains(pointer) }) {
      return under
    }
    let areas = screens.map { screen -> CGFloat in
      let common = screen.frame.intersection(frame)
      return common.isNull ? 0 : common.width * common.height
    }
    let best = areas.indices.max { areas[$0] < areas[$1] } ?? 0
    return areas[best] > 0 ? best : 0
  }

  /// 夹进可见区：整块都在里面，位置取整到整点。大小不小于 minSize；比可见区还大的缩到可见区那么大
  static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
    let width = min(max(frame.width, minSize.width), visible.width).rounded()
    let height = min(max(frame.height, minSize.height), visible.height).rounded()
    // 顶边不动地改大小（改了的话）：头部和把手在顶上
    let top = min(max(frame.maxY, visible.minY + height), visible.maxY)
    let x = min(max(frame.minX, visible.minX), visible.maxX - width)
    return CGRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
  }

  /// 落下、屏幕变了之后该在哪：算出在哪块屏，整块夹进它的可见区。一块屏都没有时原样返回
  static func settled(_ frame: CGRect, pointer: CGPoint? = nil, in screens: [NoteDeckScreen])
    -> CGRect
  {
    guard let index = home(of: frame, pointer: pointer, in: screens) else { return frame }
    return clamped(frame, in: screens[index].visibleFrame)
  }

  /// 不靠拖浮出来（操作菜单、全部便签窗口）摆在哪：从那叠里出来的（sheet 是它在那叠里的位置）比原处往屏幕里面挪
  /// floatInset；没有原处的摆在鼠标所在屏可见区的正中。都夹进可见区
  static func placed(
    size: CGSize, sheet: CGRect?, edge: NoteDeckOptions.Edge, mouse: CGPoint,
    in screens: [NoteDeckScreen]
  ) -> CGRect {
    if let sheet {
      let start = lifted(sheet: sheet, size: size, tabOnLeading: edge == .right)
      return settled(
        start.offsetBy(dx: edge == .right ? -floatInset : floatInset, dy: 0), in: screens)
    }
    let centered = { (visible: CGRect) in
      CGRect(
        x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width,
        height: size.height)
    }
    guard let index = home(of: .zero, pointer: mouse, in: screens) else { return centered(.zero) }
    return clamped(centered(screens[index].visibleFrame), in: screens[index].visibleFrame)
  }

  /// 收回时替身朝哪边滑多远（x 方向）：朝那叠所在的那条边；屏幕边缘没有那叠（nil）就不滑、只淡
  static func tuckOffset(toward edge: NoteDeckOptions.Edge?) -> CGFloat {
    switch edge {
    case .right: tuckSlide
    case .left: -tuckSlide
    case nil: 0
    }
  }

  // MARK: 哪些能浮着

  /// 这条便签能不能浮着：还在、没归档、没进最近删除
  static func floats(_ note: Note?) -> Bool {
    note?.isActive ?? false
  }

  // MARK: 记下的

  /// 记下的大小（Prefs.notesFloatSize 里的字符串，拉过大小之后写）：没记过、读不出来就用 fallback；不小于 minSize。
  /// 给了 limit（它要出现的那块屏的可见区）就不大过它：在大外接屏上拉大的、回到笔记本上拖出来，偏好被写坏成天文数字，
  /// 都不会建出伸出屏幕的窗口（比 minSize 还小的屏按屏算，同 clamped）
  static func size(stored: String?, fallback: CGSize, limit: CGSize? = nil) -> CGSize {
    let read = stored.map(NSSizeFromString) ?? .zero
    let valid = read.width.isFinite && read.height.isFinite && read.width > 0 && read.height > 0
    let size = valid ? read : fallback
    return CGSize(
      width: min(max(size.width, minSize.width), limit?.width ?? .infinity).rounded(),
      height: min(max(size.height, minSize.height), limit?.height ?? .infinity).rounded())
  }

  /// 固定着浮在屏幕上的那一张：哪条便签、在哪（Prefs.notesFloatPlace；这台电脑自己的状态）
  struct Place: Equatable, Sendable {
    var id: String
    var frame: CGRect

    init(id: String, frame: CGRect) {
      self.id = id
      self.frame = frame
    }

    /// 读偏好里那一项。不是这个样子的（没存过、别的东西写的、数不是有限数）是 nil
    init?(stored: Any?) {
      guard let stored = stored as? [String: String], let id = stored["id"], !id.isEmpty,
        let text = stored["frame"]
      else { return nil }
      let frame = NSRectFromString(text)
      guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
        frame.width > 0, frame.height > 0
      else { return nil }
      self.init(id: id, frame: frame)
    }

    /// 存进偏好的样子
    var stored: [String: String] { ["id": id, "frame": NSStringFromRect(frame)] }
  }

  /// 现在该记什么：浮着、已经落下、而且这条便签固定着，就记它在哪；别的时候不记（nil = 把记着的删掉）——
  /// 没固定的不跨重启
  static func place(id: String?, isDragging: Bool, note: Note?, frame: CGRect) -> Place? {
    guard let id, !isDragging, let note, note.id == id, floats(note), note.isPinned else {
      return nil
    }
    return Place(id: id, frame: frame)
  }

  /// 重启后要不要让它回来、回到哪：记着的那条便签还在、没归档没删、还固定着才回来；位置夹进现在看得见的屏幕
  /// （原来那块屏不在了就到主显示器）。不回来是 nil
  static func restored(_ place: Place?, note: Note?, in screens: [NoteDeckScreen]) -> CGRect? {
    guard let place, let note, note.id == place.id, floats(note), note.isPinned, !screens.isEmpty
    else { return nil }
    return settled(place.frame, in: screens)
  }
}
