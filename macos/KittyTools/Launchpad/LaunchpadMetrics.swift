// 启动台一块屏上的网格尺寸（从 LaunchpadModel 拆出来，2026-10-18）：按屏幕大小和行列数算格子、图标、搜索框、页点、
// 文件夹面板的大小和位置。界面和拖动判定共用这一份算式。

import CoreGraphics
import Foundation

/// 一块屏上的网格尺寸（按屏幕大小算；SPEC R2）。比例照 macOS 15 的官方截图量（2026-10-18 真机反馈「和 macOS 15 差很多」）：
/// 7 × 5 时网格占屏宽 80%、屏高 79%，从 8% 屏高处开始（第一行图标中心约在 15%）；图标约屏宽的 5.4%；
/// 搜索框中心在 6.7% 屏高、宽约 1/6 屏宽；页点在 90.5%。行列数改了网格总面积不变，格子跟着缩放。
nonisolated struct LaunchpadMetrics {
  let size: CGSize
  let columns: Int
  let rows: Int

  var gridWidth: CGFloat { size.width * 0.80 }
  var gridHeight: CGFloat { size.height * 0.79 }
  /// 网格左右各留多少（网格在页容器里居中）
  var side: CGFloat { (size.width - gridWidth) / 2 }
  var cellWidth: CGFloat { gridWidth / CGFloat(max(columns, 1)) }
  var cellHeight: CGFloat { gridHeight / CGFloat(max(rows, 1)) }
  /// 图标边长：约屏宽的 5.4%，受格子限制（放得下图标 + 一行名字），最小 40、最大 140
  var icon: CGFloat {
    max(40, min(140, size.width * 0.054, cellWidth * 0.62, (cellHeight - 30) * 0.86))
  }
  var labelWidth: CGFloat { cellWidth - 14 }
  /// 名字的字号（macOS 15 是白色小字）
  static let labelSize: CGFloat = 11

  static let searchHeight: CGFloat = 28
  var searchWidth: CGFloat { max(200, size.width / 6) }
  /// 搜索框上沿
  var searchTop: CGFloat { max(12, size.height * 0.067 - Self.searchHeight / 2) }
  /// 网格上沿（矮屏上让开搜索框）
  var gridTop: CGFloat { max(size.height * 0.08, searchTop + Self.searchHeight + 8) }
  /// 页点的中心
  var dotsY: CGFloat { max(size.height * 0.905, gridTop + gridHeight + 8) }

  // 文件夹面板（照 macOS 15：在屏幕中间展开，图标和主网格一样大，G4 起格子宽高分开算）
  var folderIcon: CGFloat { icon }
  /// 名字那一行的高（11 pt 字）
  static let folderLabelHeight: CGFloat = 15
  /// 图标和名字之间
  static let folderLabelSpacing: CGFloat = 5
  /// 面板四边的留白
  static let folderPadding: CGFloat = 28
  /// 文件夹名那一行的高、和面板隔多少
  static let folderTitleHeight: CGFloat = 38
  static let folderTitleSpacing: CGFloat = 18
  /// 格子里那一组（选中底 1.22 倍 + 间距 + 一行字）竖着居中：图标中心比格子中心高多少（主网格和文件夹里都是 (6 + 14) / 2）
  static let iconLift: CGFloat = 10
  /// 格子宽：和主网格一样，屏太窄时收到面板放得下
  var folderCellWidth: CGFloat {
    min(
      cellWidth, (size.width - 48 - Self.folderPadding * 2) / CGFloat(LaunchpadLayout.folderColumns)
    )
  }
  var folderCellHeight: CGFloat {
    folderIcon * 1.22 + Self.folderLabelSpacing + Self.folderLabelHeight + 12
  }
  /// 名字最宽多少（比格子窄一点，两格的名字中间留缝）
  var folderLabelWidth: CGFloat { folderCellWidth - 14 }
  var folderGridWidth: CGFloat { folderCellWidth * CGFloat(LaunchpadLayout.folderColumns) }
}
