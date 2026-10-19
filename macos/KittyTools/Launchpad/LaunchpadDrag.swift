// 启动台拖动用到的值类型和纯函数（从 LaunchpadModel 拆出来，2026-10-18）：拖动的几个时长、正在拖的那一格、松手后滑进落点的那一份，
// 指针在格子里的哪一块 / 落点怎么变 / 第几格（单测直接喂）。拖动的状态和流程（按下、挪、停、翻页、松手）在 LaunchpadModel 的「拖动」一节。

import CoreGraphics
import Foundation

/// 拖动的几个时长（照同类里最像 macOS 15 的那个取的数，2026-10-18；真值拿不到，真机手感不对就改这里）
nonisolated struct LaunchpadDragTiming: Sendable {
  /// 指针停多久别的图标才让位
  var reflow: Duration = .milliseconds(150)
  /// 停在图标中心多久算要合成（出底板）
  var combine: Duration = .milliseconds(400)
  /// 合成底板出来以后，停在文件夹上再过多久打开它（合起来约 1 s）
  var folderOpen: Duration = .milliseconds(600)
  /// 停在屏幕边上多久翻页
  var edgeDwell: Duration = .milliseconds(400)
  /// 一直停在边上，之后每隔多久再翻一页
  var edgeRepeat: Duration = .milliseconds(600)

  static let macOS15 = LaunchpadDragTiming()
  /// 单测：让位不等（指针一到落点就换上去），别的照旧
  static let immediate = LaunchpadDragTiming(reflow: .zero)
}

/// 松手 / 取消之后那份跟手的滑进落点（滑回原位）：界面按它画，到了就清掉
nonisolated struct LaunchpadLanding: Equatable {
  var tile: LaunchpadTile
  var position: CGPoint
  var scale: CGFloat
  var opacity: Double
}

/// 正在拖的那一格（R5）：起点、跟手的位移、算出来的落点、停在哪个图标中心上、要不要在边缘停着翻页。
nonisolated struct LaunchpadDrag: Equatable {
  var tileID: String
  /// 拖的是 App 时它的 id（拖出文件夹、删 App 要）
  var appID: String?
  /// 从打开的文件夹里拖出来时是那个文件夹
  var sourceFolder: UUID?
  /// 按下时指针在面板里的位置
  var start: CGPoint
  var translation: CGSize = .zero
  /// 挪过阈值才算拖（没到松手 = 点了一下）
  var active = false
  /// 当前页里的落点（拿掉这一格之后的插入位置；nil = 拖到空白处，放这一页末尾）
  var targetIndex: Int?
  /// 指针在某个图标的图标区中心停够了（要合成）：那一格的 id
  var combineTileID: String?
  /// 文件夹开着时（从里面拖出来的、或停在文件夹上打开的）落点：这一页里的第几格（nil = 末尾）
  var folderTarget: Int?
  /// 指针进过开着的文件夹面板没有（停在文件夹上打开时指针可能还在面板外：进去过再出来才算拖出去）
  var enteredFolder = false
  /// 跟手那一份的中心比指针偏多少（按下时指针在图标哪儿就一直在哪儿，不跳到中心）
  var grabOffset: CGSize = .zero
  /// 按下时在第几页（取消时只有还在这一页才滑回原位）
  var startPage = 0
  /// 停在左右边缘时准备翻到哪一页（== 页数 = 最后一页再往右）
  var turnPage: Int?
  /// 在最后一页的右边缘停够了：松手新开一页放它（G10）
  var appendsPage = false

  var offset: CGSize { translation }
  var isDragging: Bool { active }
}

extension LaunchpadModel {
  /// 指针在一格里的哪一块：中心区（内缩 20%，合成用）/ 左半 / 右半
  nonisolated enum DropZone: Equatable {
    case before, center, after
  }

  nonisolated static func zone(
    of location: CGPoint, cell: Int, in frame: CGRect, metrics: LaunchpadMetrics, center: Bool
  ) -> DropZone {
    let rect = cellRect(cell, in: frame, metrics: metrics)
    if center, rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2).contains(location) {
      return .center
    }
    return location.x < rect.midX ? .before : .after
  }

  /// 指针在第 `cell` 格（画出来的位置）的 `zone` 里时，落点和合成候选怎么变（G3，纯函数）。
  /// 画出来的格子 = 拿掉被拖那格后的列表在 `gap` 处插了一个空位：空位前面第 c 格是列表的第 c 个，空位后面是第 c − 1 个。
  /// - 指针在空位上：都不变；
  /// - 在某个图标的左 / 右边上：插到它前 / 后（它自己不挪，指针下面的还是它，不会追着跑）；
  /// - 在它的中心区：它是合成候选，空位不动；
  /// - 在最后一个后面的空格子里：放到末尾。
  nonisolated static func dropTarget(cell: Int, zone: DropZone, gap: Int, count: Int) -> (
    target: Int?, combine: Int?
  ) {
    if cell == gap { return (nil, nil) }
    let index = cell < gap ? cell : cell - 1
    guard index < count else { return (count, nil) }
    switch zone {
    case .center: return (nil, index)
    case .before: return (index, nil)
    case .after: return (index + 1, nil)
    }
  }

  /// 第几格在页容器里的矩形（网格居中、两边各留 side）
  nonisolated static func cellRect(_ index: Int, in frame: CGRect, metrics: LaunchpadMetrics)
    -> CGRect
  {
    let insetX = max(0, (frame.width - metrics.gridWidth) / 2)
    let column = index % max(metrics.columns, 1)
    let row = index / max(metrics.columns, 1)
    return CGRect(
      x: frame.minX + insetX + CGFloat(column) * metrics.cellWidth,
      y: frame.minY + CGFloat(row) * metrics.cellHeight,
      width: metrics.cellWidth, height: metrics.cellHeight)
  }

  /// 页容器里的坐标 → 第几格（纯函数，单测直接喂）。页容器是全宽的，网格居中、两边各留 side（F2）
  nonisolated static func cellIndex(
    at location: CGPoint, in frame: CGRect, metrics: LaunchpadMetrics
  ) -> Int? {
    let insetX = max(0, (frame.width - metrics.gridWidth) / 2)
    let x = location.x - frame.minX - insetX
    let y = location.y - frame.minY
    guard x >= 0, y >= 0, metrics.cellWidth > 0, metrics.cellHeight > 0 else { return nil }
    let column = Int(x / metrics.cellWidth)
    let row = Int(y / metrics.cellHeight)
    guard (0..<metrics.columns).contains(column), (0..<metrics.rows).contains(row) else {
      return nil
    }
    return row * metrics.columns + column
  }

  /// 指针是不是停在那一格的图标区中心附近（内缩 20%）。居中是「要合成」的判定之一（F1）
  nonisolated static func isInIconCenter(
    _ location: CGPoint, cell index: Int, in frame: CGRect, metrics: LaunchpadMetrics
  ) -> Bool {
    zone(of: location, cell: index, in: frame, metrics: metrics, center: true) == .center
  }
}
