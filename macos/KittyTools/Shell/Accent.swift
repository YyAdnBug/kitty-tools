// 强调色（设置 › 通用「强调色」，mac-whisker §3「颜色」）：「跟随系统」+ 和系统设置同一排的 8 色（粉色那格换成品牌粉）。
// 跟随系统（默认）= 本 App 什么都不覆盖：系统强调色是「多色」时就是 AccentColor.colorset 的品牌粉，选了具体颜色就跟它走
// （系统强调色变了自绘部分跟着重算）；选了 8 色之一 = 自绘部分用它，系统控件（开关、复选框、单选、进度条、主按钮、
// 文字选中）靠面板和设置窗根视图的 `.accentColor(_:)` 跟上（`.tint` 会把没设前景色的无边框图标按钮一起染色，
// 还管不到复选框和单选；实测 macOS 15.7）。
// ponytail: 菜单高亮、键盘焦点环是 AppKit 自己画的，没有公开 API 能改，选了 8 色时它们仍是系统强调色
// （设置窗侧栏选中改成了自绘，SettingsWindow.swift 文件头）。
// 界面一律从 Style.brand / brandInk / onBrand / Shot.accent 取，它们读这里（@Observable：换色后读过它的视图自动重画）；
// AppKit 图层在创建时取一次（截图遮罩、长截图每次新建）。不读 NSColor.controlAccentColor（社区报告调用它会让「多色」下
// 部分 AppKit 控件退回系统蓝，FB13688723），跟随系统时用 NSColor(Color.accentColor) 解析。

import AppKit
import SwiftUI

enum AccentChoice: String, CaseIterable, Identifiable {
  case system, blue, purple, pink, red, orange, yellow, green, graphite

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "跟随系统"
    case .blue: "蓝色"
    case .purple: "紫色"
    case .pink: "品牌粉"
    case .red: "红色"
    case .orange: "橙色"
    case .yellow: "黄色"
    case .green: "绿色"
    case .graphite: "石墨色"
    }
  }

  /// 浅色 / 深色下的值：系统设置里各强调色的实测值（macOS 15.7 的 controlAccentColor，不是同名的 systemXxx），
  /// 粉色换成品牌粉。跟随系统为 nil（运行时解析）
  var fixed: (light: NSColor, dark: NSColor)? {
    switch self {
    case .system: nil
    case .blue: (srgb(0x007AFF), srgb(0x007AFF))
    case .purple: (srgb(0x953D96), srgb(0xA550A7))
    case .pink: (AccentPalette.brandPink, AccentPalette.brandPink)
    case .red: (srgb(0xE0383E), srgb(0xFF5257))
    case .orange: (srgb(0xF7821B), srgb(0xF7821B))
    case .yellow: (srgb(0xFFC726), srgb(0xFFC600))
    case .green: (srgb(0x62BA46), srgb(0x62BA46))
    case .graphite: (srgb(0x989898), srgb(0x8C8C8C))
    }
  }
}

/// 一种强调色在各处的取值（纯计算；品牌粉用定好的值，其余按对比度算）
struct AccentPalette {
  /// 填充（主按钮、当前工具、勾选、生效的胶囊……）
  let fill: (light: NSColor, dark: NSColor)
  /// 「增强对比度」时的填充：白字 ≥ 4.5:1
  let contrastFill: NSColor
  /// 文字：浅色下 ≥ 4.5:1（白底），深色下提亮
  let ink: (light: NSColor, dark: NSColor)
  /// 填充上的符号 / 文字：白色；白色不够 3:1（橙、绿、浅色的石墨、黄）时 black 0.85
  let onFill: (light: NSColor, dark: NSColor)

  /// 品牌粉 #FF4D7E（深浅色同值：深色若提亮，白字只剩 2.7:1）；App 图标、DMG、截图标注的粉色点也是它
  static let brandPink = srgb(0xFF4D7E)

  /// 品牌粉：白字约 3.2:1，增强对比度时压深到 #D12A5F（5:1）；文字 #D12A5F / 深 #FF8FAB
  static let brand = AccentPalette(
    fill: (brandPink, brandPink), contrastFill: srgb(0xD12A5F),
    ink: (srgb(0xD12A5F), srgb(0xFF8FAB)), onFill: (.white, .white))

  static func make(light: NSColor, dark: NSColor) -> AccentPalette {
    if matches(light, brandPink), matches(dark, brandPink) { return brand }
    let ink = darkened(light, toContrast: 4.5)
    return AccentPalette(
      fill: (light, dark), contrastFill: ink,
      ink: (ink, dark.blended(withFraction: 0.37, of: .white) ?? dark),
      onFill: (onColor(light), onColor(dark)))
  }

  /// WCAG 相对亮度
  static func luminance(_ color: NSColor) -> CGFloat {
    guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
    func linear(_ value: CGFloat) -> CGFloat {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
      * linear(rgb.blueComponent)
  }

  static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
  }

  /// 往黑里调，直到和白色的对比度够 ratio（至少调 18%，文字比填充深一档）
  private static func darkened(_ color: NSColor, toContrast ratio: CGFloat) -> NSColor {
    var fraction: CGFloat = 0.18
    var result = color.blended(withFraction: fraction, of: .black) ?? color
    while contrast(result, .white) < ratio, fraction < 1 {
      fraction += 0.02
      result = color.blended(withFraction: fraction, of: .black) ?? color
    }
    return result
  }

  /// 白色在填充上够非文本 3:1 就用白（品牌粉 3.2、蓝 4.0），不够（橙、绿、浅色的石墨、黄）用 black 0.85
  private static func onColor(_ fill: NSColor) -> NSColor {
    contrast(.white, fill) >= 3 ? .white : .black.withAlphaComponent(0.85)
  }

  private static func matches(_ a: NSColor, _ b: NSColor) -> Bool {
    guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
    let tolerance: CGFloat = 1.5 / 255
    return abs(a.redComponent - b.redComponent) < tolerance
      && abs(a.greenComponent - b.greenComponent) < tolerance
      && abs(a.blueComponent - b.blueComponent) < tolerance
  }
}

/// 当前强调色：选择存在 `Prefs.accent`，改了立刻生效（不用重启）
@Observable final class Accent {
  static let shared = Accent()

  private(set) var choice: AccentChoice
  private(set) var palette: AccentPalette
  /// Style.brand / brandInk / onBrand 的实体（换色时重建一次，视图读的是它们）
  private(set) var brand = Color.clear
  private(set) var ink = Color.clear
  private(set) var onBrand = Color.clear

  /// 系统控件的覆盖色（根视图的 `.accentColor(_:)`）：跟随系统时不覆盖
  var controlOverride: Color? { choice == .system ? nil : brand }

  private init() {
    choice =
      AccentChoice(rawValue: UserDefaults.standard.string(forKey: Prefs.accent) ?? "") ?? .system
    palette = .brand
    refresh()
    // 跟随系统时，用户在系统设置里换了强调色（或多色 ↔ 具体颜色）
    NotificationCenter.default.addObserver(
      forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { if self?.choice == .system { self?.refresh() } }
    }
  }

  /// persists：截图自检只换颜色出图、不写用户的偏好（传 false）
  func select(_ choice: AccentChoice, persists: Bool = true) {
    if persists { UserDefaults.standard.set(choice.rawValue, forKey: Prefs.accent) }
    self.choice = choice
    refresh()
  }

  private func refresh() {
    let (light, dark) = choice.fixed ?? Self.systemAccent()
    palette = .make(light: light, dark: dark)
    brand = Style.dynamic(
      light: palette.fill.light, dark: palette.fill.dark,
      contrast: (palette.contrastFill, palette.contrastFill))
    ink = Style.dynamic(light: palette.ink.light, dark: palette.ink.dark)
    onBrand = Style.dynamic(
      light: palette.onFill.light, dark: palette.onFill.dark, contrast: (.white, .white))
  }

  /// 系统强调色（「多色」时是本 App 的 AccentColor.colorset）在浅 / 深色下的值
  private static func systemAccent() -> (light: NSColor, dark: NSColor) {
    func resolve(_ name: NSAppearance.Name) -> NSColor {
      var resolved: NSColor?
      NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
        resolved = NSColor(Color.accentColor).usingColorSpace(.sRGB)
      }
      return resolved ?? AccentPalette.brandPink
    }
    return (resolve(.aqua), resolve(.darkAqua))
  }
}

extension View {
  /// 面板、设置窗的根视图挂一次：选了具体强调色时让系统控件跟上（跟随系统时不覆盖）
  func appAccent() -> some View { accentColor(Accent.shared.controlOverride) }
}

private func srgb(_ hex: Int) -> NSColor {
  NSColor(
    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
