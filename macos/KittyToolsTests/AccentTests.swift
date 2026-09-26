// 强调色（Shell/Accent.swift）：品牌粉用定好的值；其余 8 色的文字色、增强对比度填充对白底 ≥ 4.5:1，
// 亮色（黄）上的符号换深色；跟随系统能解析出颜色（本机「多色」时是品牌粉）

import AppKit
import Testing

@testable import KittyTools

struct AccentTests {
  @Test func brandPinkKeepsItsTunedValues() {
    let palette = AccentPalette.make(light: AccentPalette.brandPink, dark: AccentPalette.brandPink)
    #expect(hex(palette.fill.light) == "FF4D7E")
    #expect(hex(palette.contrastFill) == "D12A5F")
    #expect(hex(palette.ink.light) == "D12A5F")
    #expect(hex(palette.ink.dark) == "FF8FAB")
    #expect(palette.onFill.light == .white)
    #expect(hex(AccentChoice.pink.fixed!.light) == "FF4D7E")
  }

  @Test(arguments: AccentChoice.allCases.filter { $0 != .system })
  func inkAndContrastFillAreReadable(_ choice: AccentChoice) {
    let fixed = choice.fixed!
    let palette = AccentPalette.make(light: fixed.light, dark: fixed.dark)
    #expect(AccentPalette.contrast(palette.ink.light, .white) >= 4.5)
    #expect(AccentPalette.contrast(palette.contrastFill, .white) >= 4.5)
    // 深色面板底（约 #262626）上的文字
    #expect(AccentPalette.contrast(palette.ink.dark, NSColor(white: 0.15, alpha: 1)) >= 4.5)
  }

  @Test func brightFillsGetDarkSymbols() {
    let yellow = AccentChoice.yellow.fixed!
    #expect(AccentPalette.make(light: yellow.light, dark: yellow.dark).onFill.light != .white)
    let blue = AccentChoice.blue.fixed!
    #expect(AccentPalette.make(light: blue.light, dark: blue.dark).onFill.light == .white)
  }

  /// 填充上的符号对填充至少非文本 3:1（black 0.85 按叠在填充上的实际颜色算）
  @Test(arguments: AccentChoice.allCases.filter { $0 != .system })
  func symbolsOnFillAreVisible(_ choice: AccentChoice) {
    let fixed = choice.fixed!
    let palette = AccentPalette.make(light: fixed.light, dark: fixed.dark)
    for (fill, on) in [(fixed.light, palette.onFill.light), (fixed.dark, palette.onFill.dark)] {
      let shown = fill.blended(withFraction: on.alphaComponent, of: on.withAlphaComponent(1))!
      #expect(AccentPalette.contrast(shown, fill) >= 3, "\(choice)")
    }
  }

  @Test func followingSystemResolvesAColor() {
    let fill = Accent.shared.palette.fill.light
    #expect(fill.usingColorSpace(.sRGB) != nil)
    print("system accent:", hex(fill), hex(Accent.shared.palette.fill.dark))
  }

  private func hex(_ color: NSColor) -> String {
    let rgb = color.usingColorSpace(.sRGB)!
    return String(
      format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
  }
}
