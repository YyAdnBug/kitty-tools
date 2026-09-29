// 菜单栏图标与菜单（Whisker §6 菜单栏，D 阶段）：从 SwiftUI MenuBarExtra 迁到 NSStatusItem 才能给图标做动效——
// 主动完成一件事时弹一下（pop），长任务期间呼吸（opacity 1 ↔ 0.45，1.2 s 往返），被动的剪贴板采集不播；
// 减弱动态效果时都不动。刘海岛出「进行中」就呼吸、出「成功」就弹（Island.onToneChange），截图飞行卡片落地也弹。
// 菜单每次打开前重建（快捷键、钉图状态会变），用 sectionHeader 分 剪贴板与启动器 / 翻译 / 截图 三节（N15，AppDelegate 按
// HotKeyAction.sections 填，和快捷键页同名同序），菜单项左侧是家族色符号，没设快捷键的右边留空。
// 不对应全局热键的项（暂停记录、复制即译、钉图、设置、关于、检查更新）是 MenuExtra，启动器的内置动作读同一份。
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
    image?.accessibilityDescription = "Kitty Tools"
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

/// 菜单栏里不对应全局热键的项（体检 A26）：启动器的内置动作和菜单栏同一份标题、符号、家族色和位置（同名同序）。
/// rawValue 是启动器使用记录里的 id（改了会丢记录）；「快捷键速查表」只在启动器里，「退出」只在菜单里
enum MenuExtra: String, CaseIterable {
  case pauseClipboard = "pause-clipboard"
  case copyToTranslate
  case pinsToggle = "pins-toggle"
  case pinsClose = "pins-close"
  case settings, shortcuts, about, updates

  /// 接在哪一节的末尾（那一节里有这个热键动作）；nil = 最后的设置那一节
  var section: HotKeyAction? {
    switch self {
    case .pauseClipboard: .clipboard
    case .copyToTranslate: .selectionTranslate
    case .pinsToggle, .pinsClose: .screenshot
    case .settings, .shortcuts, .about, .updates: nil
    }
  }

  /// 菜单里的标题（打开窗口的按菜单习惯带「…」，启动器里去掉）；pinsHidden：钉图藏着时写「显示全部钉图」
  func title(pinsHidden: Bool = false) -> String {
    switch self {
    case .pauseClipboard: "暂停记录剪贴板"
    case .copyToTranslate: "复制即译"
    case .pinsToggle: pinsHidden ? "显示全部钉图" : "隐藏全部钉图"
    case .pinsClose: "关闭全部钉图"
    case .settings: "设置…"
    case .shortcuts: "快捷键速查表"
    case .about: "关于 Kitty Tools"
    case .updates: "检查更新…"
    }
  }

  /// 英文别名（启动器匹配用）
  var alias: String {
    switch self {
    case .pauseClipboard: "Pause Clipboard Recording"
    case .copyToTranslate: "Copy to Translate"
    case .pinsToggle: "Show Hide Pins"
    case .pinsClose: "Close Pins"
    case .settings: "Settings Preferences"
    case .shortcuts: "Keyboard Shortcuts"
    case .about: "About"
    case .updates: "Check for Updates"
    }
  }

  var symbol: String {
    switch self {
    case .pauseClipboard: "pause.circle"
    case .copyToTranslate: "doc.on.doc"
    case .pinsToggle: "pin"
    case .pinsClose: "pin.slash"
    case .settings: "gearshape"
    case .shortcuts: "keyboard"
    case .about: "info.circle"
    case .updates: "arrow.triangle.2.circlepath"
    }
  }

  /// 家族色跟着所在那一节（暂停记录算剪贴板、复制即译算翻译、钉图算截图），最后一节是通用灰
  var color: Color { section?.color ?? Style.Family.general }

  /// 这时候有没有这一项：钉图两项要有钉图，检查更新要正式版
  func isAvailable(_ state: LauncherItem.ActionState) -> Bool {
    switch self {
    case .pinsToggle, .pinsClose: state.pinsHidden != nil
    case .updates: state.checksUpdates
    default: true
    }
  }

  /// 开关类的状态（菜单里打勾、启动器副标题）；不是开关的 nil
  func isOn(_ state: LauncherItem.ActionState) -> Bool? {
    switch self {
    case .pauseClipboard: state.recordingPaused
    case .copyToTranslate: state.copyToTranslate
    default: nil
    }
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
