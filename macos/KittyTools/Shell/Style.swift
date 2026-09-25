// Whisker 设计刻度（mac-whisker.mdc §3–4）：圆角、七条命名弹簧曲线、中性色与功能家族色、面板描边、
// 种类色块与键帽。界面里的圆角、曲线、选中色一律从这里取，不硬编码；新增的值至少要被三处复用才放进来。

import AppKit
import SwiftUI

enum Style {
  // MARK: 圆角（一律 continuous）

  enum Radius {
    /// 浮层面板、截图主工具栏、长截图 HUD
    static let panel: CGFloat = 16
    /// 选中高亮（面板内缩 6，16 − 6 同心）、卡片、输入框、钉图、放大镜
    static let card: CGFloat = 10
    /// 尺寸标签、小图标按钮的悬停底、分组标签
    static let control: CGFloat = 6
    /// 键帽、行内高亮、角标
    static let mini: CGFloat = 4

    /// 色块（App 图标比例）：18 → 4、24 → 5.5、30 → 7、40 → 9
    static func tile(_ side: CGFloat) -> CGFloat { side * 0.225 }
  }

  // MARK: 动效

  /// 「减弱动态效果」（AppKit 侧；SwiftUI 视图读 `@Environment(\.accessibilityReduceMotion)`）
  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// 七条命名曲线（SwiftUI `Spring(duration:bounce:)` 与 `CASpringAnimation(perceptualDuration:bounce:)` 参数一致）
  enum Motion {
    /// 按键连发、结果刷新、拖动、放大镜跟随、粘贴时收起面板：不做动画
    case instant
    /// 键盘驱动的选中高亮、范围胶囊、键帽依次出现
    case snap
    /// 指针驱动的位移：截图悬停洞、工具滑块、语言胶囊互换
    case glide
    /// 高度变化、内容交叉淡变、列表插入删除、折叠
    case settle
    /// 小东西出现：对勾、手柄、色块、钉图
    case pop
    /// 刘海岛长出来、飞行卡片落地
    case island
    /// 刘海岛缩回
    case retract

    /// (duration, bounce)；instant 为 nil
    var parameters: (duration: Double, bounce: Double)? {
      switch self {
      case .instant: nil
      case .snap: (0.16, 0.15)
      case .glide: (0.26, 0.10)
      case .settle: (0.24, 0)
      case .pop: (0.32, 0.25)
      case .island: (0.42, 0.22)
      case .retract: (0.34, 0)
      }
    }

    /// 减弱动态效果时：snap / glide 变成不做动画，其余变成 0.2 s easeInOut（调用方只改透明度）
    func animation(reduced: Bool = Style.reduceMotion) -> Animation? {
      guard let (duration, bounce) = parameters else { return nil }
      if reduced { return self == .snap || self == .glide ? nil : .easeInOut(duration: 0.2) }
      return .spring(duration: duration, bounce: bounce)
    }

    /// Core Animation 版本；减弱动态效果时退成 0.2 s 基本动画（snap / glide 返回 nil，直接设值）
    func caAnimation(keyPath: String, reduced: Bool = Style.reduceMotion) -> CAAnimation? {
      guard let (duration, bounce) = parameters else { return nil }
      if reduced {
        guard self != .snap, self != .glide else { return nil }
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.duration = 0.2
        basic.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return basic
      }
      let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
      spring.keyPath = keyPath
      spring.duration = spring.settlingDuration
      return spring
    }
  }

  /// 淡入 0.12 s easeOut / 淡出 0.10 s easeIn（面板进出、岛的内容）
  static let fadeIn: Double = 0.12
  static let fadeOut: Double = 0.10

  // MARK: 颜色

  /// 浅色取 light、深色取 dark 的动态色；「增强对比度」时换成 contrast（没给就不变）
  static func dynamic(
    light: NSColor, dark: NSColor, contrast: (light: NSColor, dark: NSColor)? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark =
          appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
          != nil
        // 高对比外观按名字匹配不到（NSAppearance 会归到普通外观），直接读系统开关；开关一变系统会重画
        if let contrast, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
          return isDark ? contrast.dark : contrast.light
        }
        return isDark ? dark : light
      })
  }

  /// 列表选中（一块灰色高亮，文字不反白）
  static let selectedFill = dynamic(
    light: .black.withAlphaComponent(0.07), dark: .white.withAlphaComponent(0.10),
    contrast: (.black.withAlphaComponent(0.16), .white.withAlphaComponent(0.22)))
  /// 悬停
  static let hoverFill = dynamic(
    light: .black.withAlphaComponent(0.04), dark: .white.withAlphaComponent(0.05))
  /// 控件底（胶囊按钮、键帽、输入框）
  static let controlFill = Color.primary.opacity(0.06)
  /// 发丝线
  static let hairline = dynamic(
    light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10),
    contrast: (.black.withAlphaComponent(0.35), .white.withAlphaComponent(0.4)))

  /// 功能家族色：启动器种类色块、设置页头、菜单图标全 App 统一
  enum Family {
    static let clipboard = Color(nsColor: .systemBlue)
    static let command = Color(nsColor: .systemPurple)
    static let screenshot = Color(nsColor: .systemPink)
    static let translate = Color(nsColor: .systemGreen)
    static let keyboard = Color(nsColor: .systemOrange)
    static let general = Color(nsColor: .systemGray)
    static let url = Color(nsColor: .systemTeal)
    static let search = Color(nsColor: .systemIndigo)
  }

  /// 品牌粉：只在品牌时刻（App 图标、关于页、引导、空状态）
  static let brand = dynamic(
    light: NSColor(red: 1, green: 0.302, blue: 0.494, alpha: 1),
    dark: NSColor(red: 1, green: 0.42, blue: 0.576, alpha: 1))
}

/// 种类色块：非 App 结果（命令、网址、搜索、计算…）和设置页头用，视觉重量和 App 图标一致
struct KindTile: View {
  let symbol: String
  let color: Color
  var size: CGFloat = 24

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.tile(size), style: .continuous)
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(
        shape.fill(
          LinearGradient(
            colors: [color.opacity(0.95), color.mix(with: .black, by: 0.18)], startPoint: .top,
            endPoint: .bottom))
      )
      .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
  }
}

/// 键帽（⌘1–9、↩、⌘K）
struct KeyCap: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: .medium, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 5)
      .frame(minWidth: 20, minHeight: 18)
      .foregroundStyle(.secondary)
      .background(Style.controlFill, in: .rect(cornerRadius: Style.Radius.mini, style: .continuous))
  }
}

/// Panel 皮肤的描边：外圈 0.5 pt 发丝线 + 内圈 1 pt 顶部高光（macOS 26 用玻璃时不画）
struct PanelRim: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.panel, style: .continuous)
    let dark = scheme == .dark
    let high = contrast == .increased
    ZStack {
      shape.strokeBorder(
        LinearGradient(
          stops: [
            .init(color: .white.opacity(dark ? 0.16 : 0.55), location: 0),
            .init(color: .white.opacity(0), location: 0.35),
          ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
      shape.strokeBorder(
        Color.black.opacity(high ? 0.25 : dark ? 0.28 : 0.10), lineWidth: high ? 1 : 0.5)
    }
    .allowsHitTesting(false)
  }
}
