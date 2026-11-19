// 框选遮罩的旁白（Whisker §7；第五轮体检 H1 从 SelectionView.swift 拆出）：整块一个分组，标签读状态、帮助读提示，主动播报，选区像素尺寸的说法。

import AppKit

extension SelectionView {
  // MARK: 旁白

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .group }
  override func accessibilityLabel() -> String? { accessibilityState }
  override func accessibilityHelp() -> String? { hintParts.joined(separator: Island.comma) }

  /// 旁白读的状态：待选（悬停着窗口时带窗口尺寸）/ 选区像素尺寸，调整时加当前工具、锁着的比例
  private var accessibilityState: String {
    guard let selection else {
      guard let mouse, let hovered = hoverRect(at: mouse) else { return String(localized: "待选") }
      let name = hoverName ?? String(localized: "窗口")
      return String(localized: "待选，\(name) \(sizeText(hovered)) 像素")
    }
    var parts = [String(localized: "选区 \(sizeText(selection)) 像素")]
    if adjusts, isAdjusting {
      if let tool { parts.append(String(localized: "当前工具：\(tool.title)")) }
      if let ratio = session.lockedRatio {
        parts.append(String(localized: "比例 \(RegionSelector.ratioTitle(ratio))"))
      }
    }
    return parts.joined(separator: Island.comma)
  }

  /// 主动播报：本 App 不激活，VoiceOver 的焦点多半不在遮罩上，状态切换要自己说出来
  func announce(_ text: String) {
    announcement = text
    Island.announce("\(text)")
  }

  /// 选区（点）在冻结帧上的像素宽高：尺寸胶囊、旁白共用
  func pixelSize(of rect: CGRect) -> (width: Int, height: Int) {
    let pixels = RegionSelector.pixelRect(
      rect, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
    return (Int(pixels.width), Int(pixels.height))
  }

  func sizeText(_ rect: CGRect) -> String {
    let size = pixelSize(of: rect)
    return "\(size.width) × \(size.height)"
  }

  /// 选区往外取整到冻结帧的像素（和 pixelRect 裁出来的正好一样）：洞、边框、手柄画在整像素上。鼠标给的是小数点
  /// （触控板），不取整时 1.5 pt 的粉线发糊，洞边还会在粉线里侧透出一道半像素的暗边
  func pixelAligned(_ rect: CGRect) -> CGRect {
    let scaleX = CGFloat(image.width) / max(bounds.width, 1)
    let scaleY = CGFloat(image.height) / max(bounds.height, 1)
    let pixels = RegionSelector.pixelRect(
      rect, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height))
    guard !pixels.isEmpty else { return rect }
    return CGRect(
      x: pixels.minX / scaleX, y: bounds.height - pixels.maxY / scaleY,
      width: pixels.width / scaleX, height: pixels.height / scaleY)
  }
}
