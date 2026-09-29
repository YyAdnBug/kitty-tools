// Whisker 设计刻度（mac-whisker.mdc §2–4、§7）：圆角、七条命名弹簧曲线、强调色（取自 Accent）、中性色与功能家族色、
// 面板描边、卡片表面（CardSurface）、发丝线（Hairline / hairlineBorder，增强对比度时 1 pt）、输入框底、复制对勾停留、
// 种类色块与键帽。界面里的圆角、曲线、强调色、选中色、发丝线一律从这里取，不硬编码；
// 新增的值至少要被三处复用才放进来。

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

  /// 当前事件是按住不放的按键连发（先瞬时，再动画）。isARepeat 只能问 keyDown / keyUp，
  /// 问鼠标、KitDefined 等事件会抛 NSInternalInconsistencyException，所以先看类型
  static var isKeyRepeat: Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp else {
      return false
    }
    return event.isARepeat
  }

  /// 当前事件是不是回车键（含小键盘 Enter）。⌃O 等也会发 insertNewline… 选择器，按选择器区分不了；
  /// 当前事件不是按键时问 keyCode 会抛异常，先看类型。36 = kVK_Return，76 = kVK_ANSI_KeypadEnter
  static var isReturnKey: Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
    return event.keyCode == 36 || event.keyCode == 76
  }

  /// 当前事件是不是鼠标双击（按钮动作里区分单击 / 双击）。只读鼠标事件的 clickCount：用键盘或 VoiceOver
  /// 激活按钮时 currentEvent 是按键事件，直接读 clickCount 会抛 NSInternalInconsistencyException
  static var isDoubleClick: Bool {
    guard let event = NSApp.currentEvent,
      event.type == .leftMouseDown || event.type == .leftMouseUp
    else { return false }
    return event.clickCount >= 2
  }

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

    /// Core Animation 版本；减弱动态效果时退成 0.2 s 基本动画（snap / glide 返回 nil，直接设值）。
    /// bounce 只给「工具栏浮现」这类规则里写明的变体用（pop 配 0.18）
    func caAnimation(
      keyPath: String, reduced: Bool = Style.reduceMotion, bounce override: Double? = nil
    ) -> CAAnimation? {
      guard let (duration, standard) = parameters else { return nil }
      let bounce = override ?? standard
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
  /// 复制后图标换成对勾、停这么久再换回（Whisker §4 符号动效）：翻译卡片、透镜 / ⌘Y 色值、翻译历史行尾共用。
  /// 剪贴板底栏的文字提示（showToast）不是符号动效，不走它
  static let copiedHold: Duration = .seconds(1.2)
  /// 自绘控件禁用时的不透明度（Whisker §3 状态）；系统控件 .disabled 自己会变淡
  static let disabledOpacity: Double = 0.35

  // MARK: 颜色

  /// 浅色取 light、深色取 dark 的动态色；「增强对比度」时换成 contrast（没给就不变）
  /// nonisolated：取色闭包由 AppKit 在解析颜色的线程上调，SwiftUI 在显示链接线程异步渲染动画（彗星边框、扫光）时
  /// 也会调；闭包默认继承主线程隔离的话，一到后台就触发执行器断言闪退（2026-09-27 实测）。闭包里只读传进来的颜色和系统开关
  nonisolated static func dynamic(
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
  /// 控件底（胶囊按钮、键帽）
  static let controlFill = Color.primary.opacity(0.06)
  /// 输入框底（Whisker §2：primary 0.045 / 深 0.07）：翻译原文框、历史搜索框、剪贴板对话框、快捷键录制框
  static let inputFill = dynamic(
    light: .black.withAlphaComponent(0.045), dark: .white.withAlphaComponent(0.07))
  /// 发丝线的颜色（增强对比度时 0.25，线宽由 Hairline / hairlineBorder 换成 1 pt，Whisker §7）
  static let hairline = dynamic(
    light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10),
    contrast: (.black.withAlphaComponent(0.25), .white.withAlphaComponent(0.25)))
  /// 发丝线宽：平时 0.5 pt，增强对比度 1 pt
  static func hairlineWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
    contrast == .increased ? 1 : 0.5
  }

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

  // MARK: 无障碍开关（AppKit 侧）

  static var reduceTransparency: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }
  static var increaseContrast: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  }

  // MARK: 截图家族

  /// 截图家族（遮罩、工具栏、样式托盘、放大镜、钉图、常驻缩略图、长截图、飞行卡片）
  enum Shot {
    /// 强调色的深色值（默认品牌粉 #FF4D7E），固定不随深浅色，给永远深色的 HUD / CALayer 用；图层在创建时取
    static var accent: NSColor { Accent.shared.palette.fill.dark }
    /// 强调色填充上的符号 / 文字（白；黄色这种亮色上是 black 0.85）
    static var onAccent: NSColor { Accent.shared.palette.onFill.dark }
    /// 当前工具的实心底块圆角（全 App 唯一一处强调色填满的块）
    static let toolRadius: CGFloat = 12
  }

  /// HUD 皮肤（永远深色，mac-whisker §2）：截图工具栏、样式托盘、尺寸胶囊、提示、放大镜信息卡、钉图圆钮、
  /// 常驻缩略图胶囊、长截图面板共用。有材质的用 NSVisualEffectView（`.hudWindow` + vibrantDark），
  /// 纯图层画的小控件用 fill；降低透明度时不透明、增强对比度时内描边加粗、小底块和分隔线加深。
  /// 截图家族里自绘的半透明 HUD 零件一律从这里取色，不写字面量（不然两个无障碍开关管不到）
  enum HUD {
    /// 纯图层控件的底色
    static var fill: NSColor { NSColor(white: 0.11, alpha: reduceTransparency ? 0.97 : 0.82) }
    /// 内圈描边 0.5 pt white 0.14（增强对比度 1 pt white 0.35）
    static var innerStroke: NSColor { .white.withAlphaComponent(increaseContrast ? 0.35 : 0.14) }
    static var strokeWidth: CGFloat { increaseContrast ? 1 : 0.5 }
    /// 外圈 0.5 pt black 0.5
    static let outerStroke = NSColor.black.withAlphaComponent(0.5)
    /// 文字三档：主 / 次 / 再次
    static let text = NSColor.white.withAlphaComponent(0.95)
    static let secondaryText = NSColor.white.withAlphaComponent(0.60)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.40)
    /// 悬停底（按钮后面 control 圆角的浅色块）white 0.10（增强对比度 0.20）
    static var hoverFill: NSColor { .white.withAlphaComponent(increaseContrast ? 0.20 : 0.10) }
    /// 分组分隔线 1 × 18 white 0.14（增强对比度 0.35）
    static var separator: NSColor { .white.withAlphaComponent(increaseContrast ? 0.35 : 0.14) }
    /// 小底块（键帽、比例按钮、分段轨道、预览槽）white 0.08（增强对比度 0.20）
    static var chipFill: NSColor { .white.withAlphaComponent(increaseContrast ? 0.20 : 0.08) }
    /// 分段里选中的那段 white 0.16（增强对比度 0.32）
    static var selectedFill: NSColor { .white.withAlphaComponent(increaseContrast ? 0.32 : 0.16) }
    /// 色点描边（黑色点在深色栏上也看得见）white 0.35（增强对比度 0.60）
    static var swatchStroke: NSColor { .white.withAlphaComponent(increaseContrast ? 0.60 : 0.35) }

    /// 遮罩里的浮动控件阴影：black 0.35、模糊 18（CALayer shadowRadius 取一半）、向下 6，必须设 shadowPath
    static func applyShadow(to layer: CALayer, path: CGPath) {
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.35
      layer.shadowRadius = 9
      layer.shadowOffset = CGSize(width: 0, height: -6)
      layer.shadowPath = path
    }

    /// 纯图层画的 HUD 小控件（尺寸胶囊、提示、信息卡）：底色 + 内描边 + 圆角，外圈 0.5 pt black 0.5 是边外 0.5 的子图层
    /// （跟着宽高伸缩，圆角大 0.5 同心；亮底上才有和工具栏一样的深色发丝边）。改了尺寸 / 圆角再调一次就行
    static func applySkin(
      to layer: CALayer, radius: CGFloat, curve: CALayerCornerCurve = .continuous
    ) {
      layer.backgroundColor = fill.cgColor
      layer.borderColor = innerStroke.cgColor
      layer.borderWidth = strokeWidth
      layer.cornerRadius = radius
      layer.cornerCurve = curve
      let name = "hud.outerStroke"
      let ring =
        layer.sublayers?.first { $0.name == name }
        ?? {
          let ring = CALayer()
          ring.name = name
          ring.borderWidth = 0.5
          ring.borderColor = outerStroke.cgColor
          ring.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
          layer.addSublayer(ring)
          return ring
        }()
      ring.frame = layer.bounds.insetBy(dx: -0.5, dy: -0.5)
      ring.cornerRadius = radius + 0.5
      ring.cornerCurve = curve
    }
  }

  /// 全 App 功能强调色（设置 › 通用「强调色」，默认跟随系统：系统是「多色」时就是品牌粉 #FF4D7E，深浅色同值、
  /// 增强对比度时压深到 #D12A5F）。取自 `Accent`：换色后读过它的视图自动重画
  static var brand: Color { Accent.shared.brand }
  /// 强调色的文字色（品牌粉：#D12A5F / 深 #FF8FAB）
  static var brandInk: Color { Accent.shared.ink }
  /// 强调色填充上的符号 / 文字（白；黄色这种亮色上是 black 0.85）
  static var onBrand: Color { Accent.shared.onBrand }
  /// 品牌奶油底（#FFF5F0 / 深 #2A1D22）：关于页、引导的底色，是品牌色、不随强调色变
  static let brandCream = dynamic(
    light: NSColor(red: 1, green: 0.961, blue: 0.941, alpha: 1),
    dark: NSColor(red: 0.165, green: 0.114, blue: 0.133, alpha: 1))
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
  /// 主按钮（底栏「粘贴 ↩」「打开 ↩」）：强调色实心 + 白色符号。只放符号：白字在品牌粉上约 3.2:1，只够非文本 3:1
  var isPrimary = false

  init(_ text: String, primary: Bool = false) {
    self.text = text
    isPrimary = primary
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: isPrimary ? .semibold : .medium, design: .rounded))
      .monospacedDigit()
      .padding(.horizontal, 5)
      .frame(minWidth: 20, minHeight: 18)
      .foregroundStyle(isPrimary ? AnyShapeStyle(Style.onBrand) : AnyShapeStyle(.secondary))
      .background(
        isPrimary ? AnyShapeStyle(Style.brand) : AnyShapeStyle(Style.controlFill),
        in: .rect(cornerRadius: Style.Radius.mini, style: .continuous))
  }
}

/// 主按钮（Whisker §3 状态：强调色实心 + onBrand 文字，按下 0.97，禁用 0.35）：关于页「更新并重新打开」、引导「继续 /
/// 开始使用」、速查表「完成」、剪贴板对话框的保存 / 创建 / 完成共用。不用系统的 .borderedProminent + tint：它的文字色
/// 由系统定，黄、橙、绿、浅色石墨这些亮强调色上也是白字（AccentPalette.onFill 这时是 black 0.85，AccentTests 锁住），
/// 而且屏外截图自检里画成灰的、看不出来。胶囊形，高度跟 controlSize（regular 22、large 30，和旁边的系统按钮一样高）；
/// 键盘等价（.defaultAction 等）照常挂在按钮上
struct BrandButtonStyle: ButtonStyle {
  @Environment(\.controlSize) private var controlSize
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let large = controlSize == .large
    configuration.label
      .lineLimit(1)
      .foregroundStyle(Style.onBrand)
      .padding(.horizontal, large ? 16 : 11)
      .frame(minHeight: large ? 30 : 22)
      .background(Style.brand, in: .capsule)
      .contentShape(.capsule)
      .opacity(isEnabled ? 1 : Style.disabledOpacity)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

/// 一个组合拆成键帽（⌘ ⇧ 这类修饰键各一个，剩下的是一个）：「⇧⌘S」→ ⇧ ⌘ S。
/// 快捷键录制框、速查表、引导、启动器选中行共用
struct KeyCombo: View {
  let combo: String

  init(_ combo: String) { self.combo = combo }

  var body: some View {
    HStack(spacing: 3) {
      ForEach(Self.caps(combo), id: \.self) { KeyCap($0) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(combo)
  }

  /// 前面的修饰键逐个拆开，其余整体一个键帽；只有修饰键时就是这几个修饰键
  static func caps(_ combo: String) -> [String] {
    let modifiers = combo.prefix { "⌃⌥⇧⌘".contains($0) }
    let rest = combo.dropFirst(modifiers.count).trimmingCharacters(in: .whitespaces)
    return modifiers.map(String.init) + (rest.isEmpty ? [] : [rest])
  }
}

/// 发丝线（分隔线）：横线（vertical 时竖线），0.5 pt `Style.hairline`，增强对比度时 1 pt。
/// 长度由外面定：横线铺满宽度，竖线用 `.frame(height:)` 给高
struct Hairline: View {
  var vertical = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let width = Style.hairlineWidth(contrast)
    Style.hairline.frame(width: vertical ? width : nil, height: vertical ? nil : width)
      .accessibilityHidden(true)
  }
}

extension InsettableShape {
  /// 沿形状内侧描一圈发丝线：0.5 pt（增强对比度 1 pt）；color 默认 `Style.hairline`（错误卡等传自己的颜色）
  func hairlineBorder(_ color: Color = Style.hairline) -> some View {
    HairlineBorder(shape: self, color: color)
  }

  /// 中性选中高亮（Style.selectedFill）在增强对比度时加的 1 pt 强调色 0.6 描边（mac-whisker §7），平时不画。
  /// 启动器、剪贴板、翻译历史、动作菜单、管理收藏夹、设置侧栏的选中高亮共用
  func contrastSelectionBorder() -> some View {
    ContrastSelectionBorder(shape: self)
  }
}

private struct ContrastSelectionBorder<S: InsettableShape>: View {
  let shape: S
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if contrast == .increased {
      shape.strokeBorder(Style.brand.opacity(0.6), lineWidth: 1).allowsHitTesting(false)
    }
  }
}

private struct HairlineBorder<S: InsettableShape>: View {
  let shape: S
  let color: Color
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    shape.strokeBorder(color, lineWidth: Style.hairlineWidth(contrast)).allowsHitTesting(false)
  }
}

/// 输入框底（Whisker §2：Style.inputFill + 发丝线（增强对比度 1 pt），圆角 card）：翻译原文框、历史搜索框、剪贴板对话框的
/// 输入框、快捷键录制框共用。拿着焦点时换成焦点环（Whisker §3「输入框焦点」：1 pt 品牌粉 0.55 描边 + 粉 0.18 外发光），淡入淡出
struct InputBox: ViewModifier {
  var isFocused = false
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let fade = Animation.easeOut(duration: Style.fadeIn)
    content
      .background(Style.inputFill, in: shape)
      // 外发光画在描边上再模糊（不给整块加 shadow：那样连里面的字都带光晕）
      .background {
        shape.stroke(Style.brand.opacity(0.18), lineWidth: 4).blur(radius: 2)
          .opacity(isFocused ? 1 : 0)
          .animation(fade, value: isFocused)
      }
      .overlay {
        shape
          .strokeBorder(
            isFocused ? Style.brand.opacity(0.55) : Style.hairline,
            lineWidth: isFocused ? 1 : Style.hairlineWidth(contrast)
          )
          .animation(fade, value: isFocused)
      }
  }
}

/// Panel 里的内容卡片表面（Whisker §2，翻译卡、词典卡、剪贴板 ⌘Y 大卡共用）：圆角 card；浅色 white 0.55、深色 white 0.06 底
/// + 发丝线描边（增强对比度 1 pt）+ 深色的顶部高光（内圈 1 pt white 0.12→clear，顶部 40%，同 PanelRim 的画法）；
/// 不加阴影（§3 层级：卡片不加阴影）。降低透明度时底换成 windowBackground 0.9（§7）。
/// tint：错误卡（systemRed）= tint 0.05 底 + tint 0.18 描边、没有高光
struct CardSurface: ViewModifier {
  var tint: Color?
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
    let dark = scheme == .dark
    content
      .background {
        ZStack {
          if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
          }
          if let tint {
            shape.fill(tint.opacity(0.05))
          } else if !reduceTransparency {
            shape.fill(.white.opacity(dark ? 0.06 : 0.55))
          }
        }
      }
      .overlay {
        shape.hairlineBorder(tint?.opacity(0.18) ?? Style.hairline)
        if dark, tint == nil {
          shape.strokeBorder(
            LinearGradient(
              stops: [
                .init(color: .white.opacity(0.12), location: 0),
                .init(color: .white.opacity(0), location: 0.4),
              ], startPoint: .top, endPoint: .bottom), lineWidth: 1
          )
          .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  /// 内容卡片表面，见 `CardSurface`
  func cardSurface(tint: Color? = nil) -> some View { modifier(CardSurface(tint: tint)) }
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
