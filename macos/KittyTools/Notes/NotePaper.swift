// 便签的纸色（PLAN §10「便签」C③，规范在 mac-whisker-notes.mdc）：8 种，Note.color 是这张表的下标。
// 每种三样颜色——纸（便签的底）、色条（纸顶上那一条、圆点的圈）、墨（纸上的字）——浅色、深色外观各一套：浅色那套是
// 便利贴的样子（浅纸深字），深色那套是同一个色相的深纸浅字（深色外观下一块浅黄的纸太刺眼），墨对纸都够 4.5:1，
// 次要的字（secondaryInk，墨的 75%）也够（NotesWindowTests 锁住）。
// 纸色是内容的颜色（同剪贴板里复制的色值、来源 App 的图标），不是强调色：不跟设置里的强调色变，也不拿它标「该操作的东西」。
// 颜色的名字用在菜单和旁白里。选颜色的地方都用同一份表（colorItems）：每一项前面是它的纸色圆点，现在的那种打勾。

import AppKit
import SwiftUI

nonisolated struct NotePaper: Equatable, Sendable {
  /// 一套颜色（0xRRGGBB，sRGB）
  struct Tone: Equatable, Sendable {
    let paper: Int
    let strip: Int
    let ink: Int
  }

  let name: String
  let light: Tone
  let dark: Tone

  /// 次要的字（「改于…」那一行、占位）用墨的这么多：再淡的话浅色那套在纸上不到 4.5:1
  static let secondaryOpacity = 0.75
  /// 做完的任务的字用墨的这么多（划了线的、已经不用看的字，有意淡下去）；增强对比度时回到 secondaryOpacity
  static let doneOpacity = 0.5
  /// 正文里露出来的 Markdown 标记（光标所在行的 # ** ` 这些）用墨的这么多——和占位同一档；增强对比度时
  /// markerContrastOpacity
  static let markerOpacity = 0.35
  static let markerContrastOpacity = 0.6
  /// 行内代码的底：墨的这么多。增强对比度时**不加深**：加到 16% 的话深色那 8 套纸上墨对底都不到 7:1，代码反而更难认
  /// （8% 时 16 套都够，NotesWindowTests 锁住）
  static let codeFillOpacity = 0.08
  /// 打开的便签带着的那张标签：纸上叠这么浓的色条色（比纸深一档；墨在上面仍够 4.5:1，NoteDeckTests 锁住）
  static let tabTint = 0.16

  static let all: [NotePaper] = [
    NotePaper(
      name: "柠檬", light: Tone(paper: 0xFCE795, strip: 0xE0AD08, ink: 0x3A3008),
      dark: Tone(paper: 0x4A4012, strip: 0xF2C230, ink: 0xFBEFB8)),
    NotePaper(
      name: "桃", light: Tone(paper: 0xFBCFA6, strip: 0xE2762A, ink: 0x422413),
      dark: Tone(paper: 0x4F3320, strip: 0xF08A45, ink: 0xFCE0C6)),
    NotePaper(
      name: "玫瑰", light: Tone(paper: 0xFAC4D1, strip: 0xDC4570, ink: 0x40161F),
      dark: Tone(paper: 0x4E2330, strip: 0xF06A8E, ink: 0xFBD5DE)),
    NotePaper(
      name: "丁香", light: Tone(paper: 0xD9C7FA, strip: 0x7C4DEE, ink: 0x2A1B44),
      dark: Tone(paper: 0x35285A, strip: 0x9D7CF5, ink: 0xE6DAFC)),
    NotePaper(
      name: "天蓝", light: Tone(paper: 0xBEDDFA, strip: 0x2280D6, ink: 0x13293A),
      dark: Tone(paper: 0x1D3A54, strip: 0x4DA3EC, ink: 0xD3E8FB)),
    NotePaper(
      name: "薄荷", light: Tone(paper: 0xB4E8D0, strip: 0x0E9B6E, ink: 0x0F2E23),
      dark: Tone(paper: 0x17402F, strip: 0x2DBE8D, ink: 0xC8F0DD)),
    NotePaper(
      name: "沙", light: Tone(paper: 0xE3D3B4, strip: 0xA37B3C, ink: 0x372C18),
      dark: Tone(paper: 0x453A26, strip: 0xC39A58, ink: 0xEEE2CA)),
    NotePaper(
      name: "石板", light: Tone(paper: 0xCBD6E2, strip: 0x4E6579, ink: 0x1A242E),
      dark: Tone(paper: 0x2C3742, strip: 0x7E97AD, ink: 0xDCE4EC)),
  ]

  /// 一条便签的纸色（下标越界的夹回来：库和导入的文件都夹过，这里只是不崩）
  static func of(_ note: Note) -> NotePaper { all[min(max(note.color, 0), all.count - 1)] }

  /// 跟着外观走的三样（AppKit 侧；SwiftUI 用下面的 Color）
  var paperColor: NSColor { Self.dynamic(light.paper, dark.paper) }
  var stripColor: NSColor { Self.dynamic(light.strip, dark.strip) }
  var inkColor: NSColor { Self.dynamic(light.ink, dark.ink) }
  /// 做完的任务的字（AppKit 侧，正文编辑器用）：墨的 doneOpacity，增强对比度时是 secondaryOpacity
  var fadedInkColor: NSColor {
    Self.dynamic(light.ink, dark.ink, alpha: Self.doneOpacity, contrastAlpha: Self.secondaryOpacity)
  }

  /// 正文里的 Markdown（AppKit 侧，正文编辑器用）：引用的字是次要的墨（增强对比度时就是墨）、露出来的标记、
  /// 行内代码的底、引用左边的竖线
  var secondaryInkColor: NSColor {
    Self.dynamic(light.ink, dark.ink, alpha: Self.secondaryOpacity)
  }
  var markerInkColor: NSColor {
    Self.dynamic(
      light.ink, dark.ink, alpha: Self.markerOpacity, contrastAlpha: Self.markerContrastOpacity)
  }
  var codeFillColor: NSColor {
    Self.dynamic(
      light.ink, dark.ink, alpha: Self.codeFillOpacity, contrastAlpha: Self.codeFillOpacity)
  }
  /// 引用左边的竖线：色条色；增强对比度时用墨色——那时引用的字回到了墨色，色条在浅纸上又淡（柠檬浅纸上对纸只有
  /// 1.68:1），只剩缩进不好认
  var quoteBarColor: NSColor {
    Self.dynamic(light.strip, dark.strip, contrast: (light.ink, dark.ink))
  }

  var paper: Color { Color(nsColor: paperColor) }
  var strip: Color { Color(nsColor: stripColor) }
  var ink: Color { Color(nsColor: inkColor) }
  var secondaryInk: Color { ink.opacity(Self.secondaryOpacity) }
  /// 纸的描边、纸上的分隔线（屏幕边缘的标签、预览卡、打开的便签）：墨的 14%，增强对比度时 45%
  /// （线宽另由 hairlineBorder / Style.hairlineWidth 加粗）
  func rule(_ contrast: ColorSchemeContrast) -> Color {
    ink.opacity(contrast == .increased ? 0.45 : 0.14)
  }
  /// 永远深色的底上用的色条色（屏幕边缘的药丸是 HUD 皮肤，不跟外观变）：取深色那套里提亮过的色条
  var brightStrip: NSColor { srgb(dark.strip) }

  /// 取色闭包由 AppKit 在解析颜色的线程上调（mac-native §3）：只读传进来的几个数和线程安全的系统开关。
  /// alpha：不透明度；contrastAlpha：增强对比度的外观下用的不透明度；contrast：增强对比度的外观下换用的那一对颜色
  /// （nil = 不换）
  static func dynamic(
    _ light: Int, _ dark: Int, alpha: Double = 1, contrastAlpha: Double = 1,
    contrast: (light: Int, dark: Int)? = nil
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark =
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
        != nil
      // 高对比外观按名字匹配不到（NSAppearance 会归到普通外观），直接读系统开关；开关一变系统会重画（同 Style.dynamic）
      let isHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      let tone: (light: Int, dark: Int) = isHighContrast ? contrast ?? (light, dark) : (light, dark)
      let color = srgb(isDark ? tone.dark : tone.light)
      let opacity = isHighContrast ? contrastAlpha : alpha
      return opacity < 1 ? color.withAlphaComponent(opacity) : color
    }
  }

  /// 菜单项里的小圆点（系统菜单只认图片）：纸色的底 + 色条色的圈，画的那一刻按菜单的外观取色。
  /// 这个画图的闭包系统可能在任何线程上调（NSImage.h 写明的），只读这张表里的数
  func swatch(side: CGFloat = 12) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { [light, dark] rect in
      let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let tone = isDark ? dark : light
      let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
      srgb(tone.paper).setFill()
      circle.fill()
      srgb(tone.strip).setStroke()
      circle.lineWidth = 1.5
      circle.stroke()
      return true
    }
  }
}

/// 正文里的六种文字颜色（PLAN §10「便签」第 8 批）：一种颜色浅色、深色外观各一个值，每个值对 8 张纸（同一外观）的
/// 对比度都 ≥ 4.5:1（NotesWindowTests.paperTable 锁住）；浅色那套是深色字（写在浅纸上），深色那套是浅色字。
/// 存的形式是正文里的 `[字]{名字}`，名字就是这里的 name（全小写）。文字颜色不是强调色、也不是纸色：不跟设置里的强调色变。
nonisolated enum NoteColor: Int, CaseIterable, Sendable {
  case red, orange, green, blue, purple, gray

  /// 正文里 `]{名字}` 的那个名字（全小写；只有这几个算）
  var name: String {
    switch self {
    case .red: "red"
    case .orange: "orange"
    case .green: "green"
    case .blue: "blue"
    case .purple: "purple"
    case .gray: "gray"
    }
  }

  /// 菜单里叫的名字
  var title: String {
    switch self {
    case .red: "红"
    case .orange: "橙"
    case .green: "绿"
    case .blue: "蓝"
    case .purple: "紫"
    case .gray: "灰"
    }
  }

  /// 浅色外观下的值（0xRRGGBB，sRGB）
  var light: Int {
    switch self {
    case .red: 0xA11A14
    case .orange: 0x8A4100
    case .green: 0x18602A
    case .blue: 0x1D4FB8
    case .purple: 0x6E2FB0
    case .gray: 0x50555C
    }
  }

  /// 深色外观下的值
  var dark: Int {
    switch self {
    case .red: 0xFF9C94
    case .orange: 0xFFB86B
    case .green: 0x7EDC8F
    case .blue: 0x8CB8FF
    case .purple: 0xD0A8FF
    case .gray: 0xB4BAC2
    }
  }

  /// 跟着外观走的颜色（AppKit 侧：正文编辑器的 foregroundColor）
  var color: NSColor { NotePaper.dynamic(light, dark) }
  /// 完成 / 取消的任务里：同墨的 doneOpacity（增强对比度时 secondaryOpacity）
  var fadedColor: NSColor {
    NotePaper.dynamic(
      light, dark, alpha: NotePaper.doneOpacity, contrastAlpha: NotePaper.secondaryOpacity)
  }

  /// 名字 → 颜色：只认全小写的这 6 个（`Red`、`RED` 都不认）
  static func named(_ name: String) -> NoteColor? { allCases.first { $0.name == name } }

  /// 色值（0xRRGGBB）→ 颜色：导出文件里只认这 6 个（大小写不分）
  static func value(_ hex: Int) -> NoteColor? {
    allCases.first { $0.light == hex || $0.dark == hex }
  }

  /// 菜单项里的小圆点（系统菜单只认图片）：画的那一刻按菜单的外观取色。闭包系统可能在任何线程上调，
  /// 只读这张表里的数（同 NotePaper.swatch）
  func swatch(side: CGFloat = 12) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { [light, dark] rect in
      let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
      srgb(isDark ? dark : light).setFill()
      circle.fill()
      return true
    }
  }
}

extension NoteColor {
  /// 右键菜单「文字颜色」那一份：六种颜色各一项（前面是这个颜色的小圆点），现在那种打勾；另加「默认颜色」（去色）。
  /// 编辑器、便签墙、预览卡用的是同一个 NoteTextView 的菜单，这里只给编辑器用（AppKit 菜单）。
  @MainActor
  static func menuItems(current: NoteColor?, choose: @escaping (NoteColor?) -> Void) -> [ActionMenu
    .Item]
  {
    allCases.map { color in
      ActionMenu.Item(
        title: color.title, image: color.swatch(side: 16), isChecked: current == color,
        id: "ink-\(color.name)"
      ) { choose(color) }
    } + [
      ActionMenu.Item(
        title: "默认颜色", isChecked: current == nil, id: "ink-default", section: 1
      ) { choose(nil) }
    ]
  }
}

extension NotePaper {
  /// 选颜色的那份表，**所有选颜色的地方共用**（全部便签窗口工具栏的下拉、行的右键菜单里的「颜色」、屏幕边缘那叠的
  /// ⌘K 子列表和圆点点出来的菜单）：8 种纸色各一项，前面是它的纸色圆点（swatch，非模板图），现在的那种打勾；
  /// 点了调 choose(下标)
  @MainActor
  static func colorItems(current: Int, choose: @escaping (Int) -> Void) -> [ActionMenu.Item] {
    all.enumerated().map { index, paper in
      ActionMenu.Item(
        title: paper.name, image: paper.swatch(side: 16), isChecked: index == current,
        id: "color-\(index)"
      ) { choose(index) }
    }
  }
}

/// 纸色圆点：纸色的底 + 色条色的圈（只有底的话，浅纸在浅色侧栏上看不见）。列表行、快速记的目的地共用；
/// 是装饰，名字由用它的地方读
struct NoteDot: View {
  let paper: NotePaper
  var size: CGFloat = 12

  var body: some View {
    Circle().fill(paper.paper)
      .overlay(Circle().strokeBorder(paper.strip, lineWidth: size >= 16 ? 2 : 1.5))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
