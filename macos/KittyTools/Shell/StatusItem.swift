// 菜单栏图标与菜单（Whisker §6 菜单栏，D 阶段）：从 SwiftUI MenuBarExtra 迁到 NSStatusItem 才能给图标做动效——
// 主动完成一件事时弹一下（pop），长任务期间呼吸（opacity 1 ↔ 0.45，1.2 s 往返），被动的剪贴板采集不播；
// 减弱动态效果时都不动。刘海岛出「进行中」就呼吸、出「成功」就弹（Island.onToneChange），截图飞行卡片落地也弹。
// 菜单每次打开前重建（快捷键、钉图状态会变），菜单项左侧是家族色符号。
// 图标是角色「探头」的剪影（资源 StatusIcon，22 × 16 pt 模板图，由 macos/brand-icons.swift 生成）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

final class StatusItem: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  /// 打开菜单前往里填菜单项（AppDelegate 给）
  var buildMenu: (NSMenu) -> Void = { _ in }
  private var isWorking = false

  override init() {
    super.init()
    let image = NSImage(named: "StatusIcon")
    image?.isTemplate = true
    image?.accessibilityDescription = "Kitty Tools Native"
    item.button?.image = image
    item.button?.wantsLayer = true
    menu.delegate = self
    item.menu = menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    buildMenu(menu)
  }

  /// 刘海岛的语气变了：进行中 → 呼吸；成功 → 停下呼吸、弹一下；其它（含收起）→ 停下
  func reflect(_ tone: Island.Tone?) {
    setWorking(tone == .progress)
    if tone == .success { pop() }
  }

  /// 主动完成一件事：图标以中心放大到 1.2 倍再弹回（pop 曲线）。按中心缩放用整矩阵：
  /// 平移 + 缩放的矩阵元素对缩放倍数是线性的，逐元素插值就等于中心缩放
  func pop() {
    guard !Style.reduceMotion, let button = item.button, let layer = button.layer,
      let spring = Style.Motion.pop.caAnimation(keyPath: "transform") as? CABasicAnimation
    else { return }
    let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
    var grown = CATransform3DMakeTranslation(center.x, center.y, 0)
    grown = CATransform3DScale(grown, 1.2, 1.2, 1)
    grown = CATransform3DTranslate(grown, -center.x, -center.y, 0)
    spring.fromValue = NSValue(caTransform3D: grown)
    spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    layer.add(spring, forKey: "pop")
  }

  /// 长任务期间呼吸（ambient，结束立刻移除）
  private func setWorking(_ working: Bool) {
    guard working != isWorking, let layer = item.button?.layer else { return }
    isWorking = working
    guard working, !Style.reduceMotion else { return layer.removeAnimation(forKey: "breathe") }
    let breathe = CABasicAnimation(keyPath: "opacity")
    breathe.fromValue = 1
    breathe.toValue = 0.45
    breathe.duration = 0.6
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(breathe, forKey: "breathe")
  }
}

extension NSMenu {
  /// 加一项：左边家族色符号；key 为空就不显示快捷键
  @discardableResult
  func addAction(
    _ title: String, symbol: String, color: NSColor, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command, run: @escaping () -> Void
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(MenuTarget.run), keyEquivalent: key)
    item.target = MenuTarget.shared
    item.representedObject = run
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(hierarchicalColor: color))
    item.keyEquivalentModifierMask = modifiers
    addItem(item)
    return item
  }
}

/// 菜单项的 target：点了就跑存在 representedObject 里的闭包（不子类化 NSMenuItem：它的 init 不是主线程隔离的）
private final class MenuTarget: NSObject {
  static let shared = MenuTarget()

  @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}

extension HotKey {
  /// NSMenuItem 的 keyEquivalent（小写字符；空格键是空格）
  var menuKeyEquivalent: String? {
    keyEquivalent.map { String($0.character) }
  }

  var modifierFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    return flags
  }
}
