// 菜单栏图标与菜单（Whisker §6 菜单栏，D 阶段）：从 SwiftUI MenuBarExtra 迁到 NSStatusItem 才能给图标做动效——
// 主动完成一件事时弹一下（pop），长任务期间呼吸（opacity 1 ↔ 0.45，1.2 s 往返），被动的剪贴板采集不播；
// 减弱动态效果时都不动。刘海岛出「进行中」就呼吸、出「成功」就弹（Island.onToneChange），截图飞行卡片落地也弹。
// 菜单每次打开前重建（快捷键、钉图状态会变），用 sectionHeader 分 剪贴板与启动器 / 翻译 / 截图与录制 三节（N15，AppDelegate 按
// HotKeyAction.sections 填，和快捷键页同名同序），菜单项左侧是家族色符号，没设快捷键的右边留空。
// 不对应全局热键的项（暂停记录、复制即译、钉图、设置、关于、检查更新、退出）是 MenuExtra，启动器的内置动作读同一份。
// 图标默认是角色「探头」的剪影（资源 StatusIcon，22 × 16 pt 模板图，由 macos/brand-icons.swift 生成）；设置 › 通用可换成
// 彩色（完整的 App 图标）或隐藏（第 9 批 M1 M2），偏好一变立刻跟着变。隐藏只是 isVisible = false，动效照常调、看不见而已；
// 隐藏后回设置靠再打开一次本 App（AppDelegate.applicationShouldHandleReopen），退出在启动器里（MenuExtra.quit）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

final class StatusItem: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  /// 打开菜单前往里填菜单项（AppDelegate 给）
  var buildMenu: (NSMenu) -> Void = { _ in }
  private var isWorking = false
  private var isApplying = false
  /// 按钮上现在是哪种图（nil = 还没设）
  private var style: IconStyle?

  /// 图标样式（设置 › 通用「图标样式」）：单色 = 角色剪影模板图（跟着菜单栏深浅反色）；彩色 = 完整的 App 图标
  /// （不反色，菜单打开时的高亮上也保持原色）
  enum IconStyle: String, CaseIterable, Identifiable {
    case template, color

    var id: String { rawValue }

    /// 偏好值 → 样式；没存过、存了认不得的值都算单色
    init(pref: String?) { self = pref.flatMap(Self.init(rawValue:)) ?? .template }

    var title: String { self == .template ? "单色" : "彩色" }

    /// 菜单栏上的图（设置页分段里的小预览也用它）
    var image: NSImage? { self == .template ? StatusItem.templateIcon : StatusItem.colorIcon }
  }

  static let templateIcon: NSImage? = {
    let image = NSImage(named: "StatusIcon")
    image?.isTemplate = true
    image?.accessibilityDescription = "Kitty Tools"
    return image
  }()

  /// 只画一次（设置页每次重画都要读它）
  static let colorIcon: NSImage = {
    let image = menuBarImage(from: NSApp.applicationIconImage)
    image.accessibilityDescription = "Kitty Tools"
    return image
  }()

  override init() {
    super.init()
    item.button?.wantsLayer = true
    menu.delegate = self
    item.menu = menu
    applyPrefs()
    // 设置 › 通用改了立刻生效（@AppStorage 写的就是 standard）；别的偏好变了也会来，没变的不碰
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyPrefs() }
    }
  }

  /// 按偏好显示 / 隐藏、换样式：启动时（AppDelegate 已 registerDefaults）和偏好一变都调。
  /// behavior 没有 .removalAllowed：按住 ⌘ 只能挪位置、拖不出菜单栏，isVisible 只有这里改，不用反过来同步回偏好
  private func applyPrefs() {
    // 防重入：isVisible 的 setter 会先把自己的 autosave 键（NSStatusItem Visible Item-N）写进 standard、同步发出
    // didChangeNotification，这时 isVisible 还没变成新值，上面的「没变不碰」拦不住，会无限递归到栈溢出
    // （2026-09-29 用户切换「在菜单栏显示图标」时崩溃，macOS 15.7.7）
    guard !isApplying else { return }
    isApplying = true
    defer { isApplying = false }
    let defaults = UserDefaults.standard
    let visible = defaults.bool(forKey: Prefs.statusItemVisible)
    if item.isVisible != visible { item.isVisible = visible }
    let style = IconStyle(pref: defaults.string(forKey: Prefs.statusItemStyle))
    guard style != self.style else { return }
    self.style = style
    item.button?.image = style.image
  }

  /// 彩色图标 = 完整的 App 图标（程序坞、访达里那张）。不交给 NSImage 按菜单栏尺寸自己挑表示：16 pt 会挑到 16 / 32 px
  /// 那两张手调简化版（Whisker §6）。取 1024 px 的大图，裁掉画布四周各 100 的留白、只留 824 的圆角方块主体，先在原分辨率上
  /// 按主体外形（超椭圆，同 brand-icons.swift）去掉底角那点烘焙阴影（缩小后再裁的话边缘像素会混进阴影的黑），
  /// 再高质量插值预先画成 @1x / @2x 两张位图。16 pt 高，和单色剪影的视觉高度一样；按钮仍是 squareLength，换样式宽度不跳
  static func menuBarImage(from icon: NSImage, points: Int = 16) -> NSImage {
    let image = NSImage(size: NSSize(width: points, height: points))
    var proposed = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    guard let source = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
      return image
    }
    let unit = CGFloat(source.width) / 1024
    let side = Int((824 * unit).rounded())
    guard
      let body = source.cropping(
        to: CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)),
      let shaped = bitmap(
        side: side,
        { context in
          context.addPath(squircle(side: CGFloat(side)))
          context.clip()
          context.draw(body, in: CGRect(x: 0, y: 0, width: side, height: side))
        })
    else { return image }
    for scale in 1...2 {
      let pixels = points * scale
      guard
        let small = bitmap(
          side: pixels,
          { context in
            context.interpolationQuality = .high
            context.draw(shaped, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
          })
      else { continue }
      let rep = NSBitmapImageRep(cgImage: small)
      rep.size = image.size
      image.addRepresentation(rep)
    }
    return image
  }

  /// 边长 side 像素的 sRGB 画布
  private static func bitmap(side: Int, _ draw: (CGContext) -> Void) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    draw(context)
    return context.makeImage()
  }

  /// App 图标主体的外形：超椭圆 |x|⁵ + |y|⁵ = 1（macOS 图标的连续圆角，同 brand-icons.swift 的 squircle）
  private static func squircle(side: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let radius = side / 2
    for step in 0..<256 {
      let angle = CGFloat(step) / 256 * 2 * .pi
      let point = CGPoint(
        x: radius + radius * copysign(pow(abs(cos(angle)), 0.4), cos(angle)),
        y: radius + radius * copysign(pow(abs(sin(angle)), 0.4), sin(angle)))
      if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
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
/// rawValue 是启动器使用记录里的 id（改了会丢记录）；「快捷键速查表」只在启动器里。「退出」两边都有（第 9 批 M1：
/// 菜单栏图标可以隐藏，那时只剩启动器能退出）
enum MenuExtra: String, CaseIterable {
  case pauseClipboard = "pause-clipboard"
  case copyToTranslate
  case pinsToggle = "pins-toggle"
  case pinsClose = "pins-close"
  case settings, shortcuts, about, updates, quit

  /// 接在哪一节的末尾（那一节里有这个热键动作）；nil = 最后的设置那一节
  var section: HotKeyAction? {
    switch self {
    case .pauseClipboard: .clipboard
    case .copyToTranslate: .selectionTranslate
    case .pinsToggle, .pinsClose: .screenshot
    case .settings, .shortcuts, .about, .updates, .quit: nil
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
    case .quit: "退出 Kitty Tools"
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
    case .quit: "Quit Kitty Tools"
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
    case .quit: "power"
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
