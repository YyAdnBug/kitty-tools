// 列表选中跟随滚动（剪贴板、启动器、翻译历史共用，mac-whisker §4「选中高亮」）：选中项被挡住时才滚，
// 要露出来的区间由调用方按分组数据的前缀和算（不量视图），经 ScrollPosition.scrollTo(y:) 滚过去；
// 看不看得见按上一次滚动的终点判断，滚动停下来还没到目标时补滚一次（SwiftUI 会吞掉动画末尾发的 scrollTo）；
// ScrollPosition 被用户或别处改过就放弃这个目标，列表被空状态换掉时复位（重建出来从顶上开始）。
// 不用 ScrollViewReader.scrollTo(id)：LazyVStack 里还没实例化的行滚不准，连按 ↓ 越过可见区后列表就不再跟着走
// （2026-09-29 用户真机报告启动器，第 10 批）。
// 按前缀和滚的前提是列表真按前缀和排。剪贴板、翻译历史只画可见区附近（ListWindow，2026-10-03）；启动器结果少，还是 LazyVStack。

import SwiftUI

enum ListReveal {
  /// 让内容坐标里 top…bottom 这一段完整露出来要滚到的 y；nil = 已经看得见（或可见区还没量到），不用滚。
  /// coveredTop：可见区顶上要让出来的高度，往上滚时空出来（剪贴板是吸顶的分组标题，没有吸顶标题的列表给和四周内缩
  /// 一样的边）；inset：列表四周内缩，往下滚时底下留这么多。目标离顶不到两倍内缩时直接回到 0，顶上不留一条缝
  static func target(
    top: CGFloat, bottom: CGFloat, visible: CGRect, coveredTop: CGFloat, inset: CGFloat
  ) -> CGFloat? {
    guard visible.height > 0 else { return nil }
    let target: CGFloat
    if top - coveredTop < visible.minY {
      target = top - coveredTop
    } else if bottom > visible.maxY {
      target = bottom + inset - visible.height
    } else {
      return nil
    }
    return target < inset * 2 ? 0 : target
  }
}

/// 只画可见区附近（剪贴板、翻译历史，2026-10-03 用户报：条目多了高亮错位、滚动和 ↑↓ 卡）：列表按前缀和排，
/// 滚动位置按段记（TracksScrollBand，跨段才重画列表），画这一段上下各多 overscan 里的项，上下用前缀和算出的高度撑开，
/// 画的位置就是高亮、跟随滚动按前缀和算的位置。不交给 LazyVStack：它没排过的行按已排过的平均高度估（标题、透镜混在里面），
/// 条目多了、一下跳得远（拖滚动条、在第一条按 ↑ 绕到最后），屏上的行和前缀和差上百行、选中的行根本没画；
/// 越往后每次布局也越贵（剪贴板 1000 条屏外实测：第 790 条附近按一下 ↓ 布局 56 ms，改后任意位置约 14 ms 连绘制）
enum ListWindow {
  /// 段高、往上下各多画多少：段内怎么滚、滚动动画落后一帧，画出来的都盖得住可见区；一段一段挪时进出的项都在可见区外
  static let bandHeight: CGFloat = 240
  static let overscan: CGFloat = 320

  /// 要画的项（下标区间，二分）。tops：每一项的顶（列表坐标），比项数多一个，最后一个是总高；band：可见区的顶
  /// （滚动内容坐标）落在第几段；inset：列表顶上的内缩（滚动内容坐标 − inset = 列表坐标）；viewport：可见区最高多高。
  /// 列表一下子变短（删了一批）时滚动位置下一帧才夹回来：先按最后一段画，别空一帧
  static func range(_ tops: [CGFloat], band: Int, inset: CGFloat, viewport: CGFloat) -> Range<Int> {
    let count = max(tops.count - 1, 0)
    let total = tops.last ?? 0
    let top = CGFloat(min(band, Int(max(total - 1, 0) / bandHeight))) * bandHeight - inset
    let (lower, upper) = (top - overscan, top + bandHeight + viewport + overscan)
    /// 第一个满足的下标（predicate 对下标单调：前面都不满足、后面都满足）
    func first(_ predicate: (Int) -> Bool) -> Int {
      var (low, high) = (0, count)
      while low < high {
        let middle = (low + high) / 2
        if predicate(middle) { high = middle } else { low = middle + 1 }
      }
      return low
    }
    let start = first { tops[$0 + 1] > lower }
    return start..<max(start, first { tops[$0] >= upper })
  }
}

/// 挂在列表的 ScrollView 上：可见区的顶跨段时改 band（ListWindow）。不在动画里改：滚进来的行不播插入过渡
struct TracksScrollBand: ViewModifier {
  @Binding var band: Int

  func body(content: Content) -> some View {
    content.onScrollGeometryChange(for: Int.self) { geometry in
      Int(max(geometry.visibleRect.minY, 0) / ListWindow.bandHeight)
    } action: { _, new in
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { band = new }
    }
  }
}

/// 挂在列表的 ScrollView 上：接管它的 scrollPosition、记下可见区；key 变了（选中换了、结果换了）就按 span
/// 露出选中项。动画和选中高亮同一条（selectionMotion：键盘 snap、连发与换列表 instant、点选 glide），
/// 减弱动态效果时 snap / glide 不做动画
struct RevealsSelection<Key: Equatable>: ViewModifier {
  @Binding var position: ScrollPosition
  let key: Key
  let motion: Style.Motion
  let coveredTop: CGFloat
  let inset: CGFloat
  /// 选中项在内容坐标里的纵向区间（含四周内缩；要一起露出来的分组标题算进下界）；nil = 没有选中
  let span: () -> ClosedRange<CGFloat>?
  /// 可见区和还没到的滚动目标放在不被观察的盒子里：只在 key、滚动阶段变化时读，滚动时改它不重画列表
  @State private var viewport = Viewport()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGRect.self) {
        $0.visibleRect
      } action: { _, rect in
        viewport.rect = rect
        dropStalePending()
        if let pending = viewport.pending, abs(rect.minY - pending.y) < 1 { viewport.pending = nil }
      }
      .onScrollPhaseChange { _, phase in
        switch phase {
        case .idle:
          // SwiftUI 的坑（第 10 批屏外实测：0.03 s 一下连按 30 下，12 个窗口里 3 个停在半路）：上一段滚动动画快停时
          // 发的 scrollTo 会被吞掉——新目标写进了 ScrollPosition，列表却停在旧目标。停下来还没到就补滚一次
          // （只补一次、不再记成待滚：差半个像素也不会来回追）
          dropStalePending()
          guard let pending = viewport.pending else { return }
          viewport.pending = nil
          if abs(viewport.rect.minY - pending.y) >= 1 {
            withAnimation(pending.motion.animation(reduced: reduceMotion)) {
              position.scrollTo(y: pending.y)
            }
          }
        case .animating: break
        // 用户自己拖、滚：不再追
        default: viewport.pending = nil
        }
      }
      .onChange(of: key) {
        dropStalePending()
        guard let span = span(),
          let y = ListReveal.target(
            top: span.lowerBound, bottom: span.upperBound, visible: viewport.destination,
            coveredTop: coveredTop, inset: inset)
        else { return }
        // 目标就是当前位置（比如已经在顶、又要回 0）：不发原地不动的 scrollTo，不然列表不动、待滚目标永远清不掉
        if viewport.pending == nil, abs(y - viewport.rect.minY) < 1 { return }
        var next = position
        next.scrollTo(y: y)
        withAnimation(motion.animation(reduced: reduceMotion)) { position = next }
        viewport.pending = (y, motion, next)
      }
      // 列表被空状态换掉（启动器没结果、历史搜不到）：滚动位置复位，重建出来的列表从顶上开始，
      // 不停在旧 y 上（新列表的 onChange 不在初始值上触发，没机会纠正）
      .onDisappear { position = ScrollPosition() }
  }

  /// 待滚目标只在 ScrollPosition 还是自己写进去的那个值时算数：用户拖动 / 滚轮、别处改了它（剪贴板换列表时回顶）、
  /// 列表复位都会换掉它，这时放弃，不再按旧终点判断、也不补滚把列表拉回去（ScrollPosition.y 要 macOS 26，整个比）
  private func dropStalePending() {
    if let pending = viewport.pending, position != pending.written { viewport.pending = nil }
  }
}

private final class Viewport {
  /// 可见区（内容坐标）
  var rect = CGRect.zero
  /// 自己发出、还没滚到的目标、曲线和写进 ScrollPosition 的值：滚到了（差不到 1 pt）清掉，停下来还没到时补滚一次
  /// （见上），用户拖动 / 滚轮或别处改了 ScrollPosition 时放弃
  var pending: (y: CGFloat, motion: Style.Motion, written: ScrollPosition)?

  /// 判断看不看得见按滚动的终点算：动画还在走时 rect 是半路上的（↓ 接着 ↑ 回到第一行时会以为已经看得见）
  var destination: CGRect {
    guard let pending else { return rect }
    return CGRect(x: rect.minX, y: pending.y, width: rect.width, height: rect.height)
  }
}
