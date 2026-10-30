// 符号名 → 图（2026-10-30 功能图标拍板 D1–D4）：功能色块里的 26 个图标是自己画的、mac 和 Windows 共用一套，
// 源在仓库根的 icons/feature/*.svg，`swift icons/build-icons.swift mac` 生成资源目录 FeatureIcons/ 里的自定义符号
// （只有 Regular-M、线条已描成面，和 SF Symbols 一样跟着字号缩放、认分层色）。名字都以 kitty. 开头。
// 符号名在 App 里一路是字符串（色块、主界面、菜单栏菜单、刘海岛、动作菜单、空状态），这里给 SwiftUI 和 AppKit 各一个入口：
// kitty. 开头的取资源目录里的，其余照旧是 SF Symbols。按钮和菜单里的通用操作不换（拍板 D2）。

import AppKit
import SwiftUI

enum SymbolImage {
  static let prefix = "kitty."

  static func isCustom(_ name: String) -> Bool { name.hasPrefix(prefix) }

  /// 配好字号的自画符号（KindTile 用，见那边的注释）。按名字和字号缓存：26 个 × 几种色块大小，
  /// 列表重画时不用每次重新配一份
  static func sized(_ name: String, pointSize: CGFloat) -> NSImage? {
    let key = "\(name)@\(pointSize)"
    if let image = cache[key] { return image }
    let image = NSImage.symbol(name)?.withSymbolConfiguration(
      .init(pointSize: pointSize, weight: .semibold))
    cache[key] = image
    return image
  }

  private static var cache: [String: NSImage] = [:]
}

extension Image {
  init(symbol name: String) {
    if SymbolImage.isCustom(name) { self.init(name) } else { self.init(systemName: name) }
  }
}

extension NSImage {
  /// 同 NSImage(systemSymbolName:)，kitty. 开头的取资源目录里的自定义符号
  static func symbol(_ name: String, accessibilityDescription: String? = nil) -> NSImage? {
    guard SymbolImage.isCustom(name) else {
      return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
    }
    guard let image = NSImage(named: name) else { return nil }
    guard let accessibilityDescription, let copy = image.copy() as? NSImage else { return image }
    copy.accessibilityDescription = accessibilityDescription  // 具名图是共用的一份，改描述先拷一份
    return copy
  }
}
