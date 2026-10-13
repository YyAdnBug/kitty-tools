// 便签的纸色（PLAN §10「便签」C③，规范在 mac-whisker-notes.mdc）：8 种，Note.color 是这张表的下标。
// 每种三样颜色——纸（便签的底）、色条（纸顶上那一条、圆点的圈）、墨（纸上的字）——浅色、深色外观各一套：浅色那套是
// 便利贴的样子（浅纸深字），深色那套是同一个色相的深纸浅字（深色外观下一块浅黄的纸太刺眼），墨对纸都够 4.5:1，
// 次要的字（secondaryInk，墨的 75%）也够（NotesWindowTests 锁住）。
// 纸色是内容的颜色（同剪贴板里复制的色值、来源 App 的图标），不是强调色：不跟设置里的强调色变，也不拿它标「该操作的东西」。
// 颜色的名字用在菜单和旁白里。

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

  var paper: Color { Color(nsColor: paperColor) }
  var strip: Color { Color(nsColor: stripColor) }
  var ink: Color { Color(nsColor: inkColor) }
  var secondaryInk: Color { ink.opacity(Self.secondaryOpacity) }

  /// 取色闭包由 AppKit 在解析颜色的线程上调（mac-native §3）：只读传进来的两个数
  private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark =
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
        != nil
      return srgb(isDark ? dark : light)
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
