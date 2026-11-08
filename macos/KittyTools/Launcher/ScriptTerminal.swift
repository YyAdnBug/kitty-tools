// 全文输出那一页认终端颜色（脚本命令第三轮 A2，对标 Raycast 的全文输出；纯函数，配单测）：SGR 颜色码 → AttributedString。
// 8 / 16 色用系统颜色，深浅色各自调过（黑、白换成文字的主次色，黄色在浅色里压暗，不然白底上看不清）；256 色和 24 位照给的；
// 背景色淡一些铺；粗体、暗、斜体、下划线、删除线。别的控制码（光标移动、标题、超链接）去掉；单独的回车同终端，回到行首、
// 后面写的盖掉这一行（ScriptCommand.carriageReturns）。岛上、粘贴、复制的照旧是去掉颜色的纯文字（ScriptCommand.clean）。

import AppKit
import SwiftUI

nonisolated enum ScriptTerminal {
  /// 当前的笔：颜色码改它，后面的字照它画
  struct Pen: Equatable {
    var foreground: Color?
    var background: Color?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var strike = false
  }

  static func styled(_ output: String) -> AttributedString {
    let text = ScriptCommand.carriageReturns(output)
    guard text.utf8.contains(0x1B) else { return AttributedString(text) }
    var result = AttributedString()
    var pen = Pen()
    var start = text.startIndex
    // CSI（ESC [ 参数 中间字节 结尾字节）、OSC（ESC ] … BEL / ESC \）、别的两字节转义
    for match in text.matches(
      of: /\u{1B}(?:\[([0-9;:?]*)[ -\/]*([@-~])|\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)?|[@-_])/)
    {
      append(text[start..<match.range.lowerBound], pen, to: &result)
      start = match.range.upperBound
      if match.output.2 == "m", let parameters = match.output.1, !parameters.contains("?") {
        apply(parameters, to: &pen)
      }
    }
    append(text[start...], pen, to: &result)
    return result
  }

  /// 一个 SGR（ESC [ … m）改笔：0 重来；38 / 48 带 5;n（256 色）或 2;r;g;b（24 位）；认不出的跳过
  static func apply(_ parameters: Substring, to pen: inout Pen) {
    // 空的算 0（ESC[m、ESC[;1m）；带冒号的子参数写法（38:2::r:g:b）少见，整段跳过
    let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map {
      $0.isEmpty ? 0 : Int($0) ?? -1
    }
    var index = 0
    while index < codes.count {
      let code = codes[index]
      switch code {
      case 0: pen = Pen()
      case 1: pen.bold = true
      case 2: pen.dim = true
      case 3: pen.italic = true
      case 4: pen.underline = true
      case 9: pen.strike = true
      case 22:
        pen.bold = false
        pen.dim = false
      case 23: pen.italic = false
      case 24: pen.underline = false
      case 29: pen.strike = false
      case 30...37: pen.foreground = basic(code - 30)
      case 39: pen.foreground = nil
      case 40...47: pen.background = basic(code - 40)
      case 49: pen.background = nil
      case 90...97: pen.foreground = basic(code - 90 + 8)
      case 100...107: pen.background = basic(code - 100 + 8)
      case 38, 48:
        let color: Color?
        if index + 2 < codes.count, codes[index + 1] == 5 {
          color = indexed(codes[index + 2])
          index += 2
        } else if index + 4 < codes.count, codes[index + 1] == 2 {
          color = rgb(codes[index + 2], codes[index + 3], codes[index + 4])
          index += 4
        } else {
          return  // 写坏了：后面的不知道怎么对，不认了
        }
        if code == 38 { pen.foreground = color } else { pen.background = color }
      default: break
      }
      index += 1
    }
  }

  /// 16 色：0–7 普通、8–15 亮色（亮色用同一套系统色，黑白两头换成灰）
  static func basic(_ index: Int) -> Color {
    switch index {
    case 0, 15: Color(nsColor: .labelColor)
    case 7, 8: Color(nsColor: .secondaryLabelColor)
    case 1, 9: Color(nsColor: .systemRed)
    case 2, 10: Color(nsColor: .systemGreen)
    case 3, 11: yellow
    case 4, 12: Color(nsColor: .systemBlue)
    case 5, 13: Color(nsColor: .systemPurple)
    default: Color(nsColor: .systemCyan)
    }
  }

  /// 浅色里的系统黄在白底上几乎看不见：压暗成土黄
  private static let yellow = Style.dynamic(
    light: NSColor(srgbRed: 0.62, green: 0.45, blue: 0, alpha: 1), dark: .systemYellow)

  /// 256 色：0–15 同 basic，16–231 是 6×6×6 的色块，232–255 是灰阶
  static func indexed(_ index: Int) -> Color? {
    switch index {
    case 0...15: return basic(index)
    case 16...231:
      let levels = [0, 95, 135, 175, 215, 255]
      let cube = index - 16
      return rgb(levels[cube / 36], levels[cube / 6 % 6], levels[cube % 6])
    case 232...255:
      let gray = 8 + (index - 232) * 10
      return rgb(gray, gray, gray)
    default: return nil
    }
  }

  static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color? {
    guard [red, green, blue].allSatisfy((0...255).contains) else { return nil }
    return Color(
      .sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
  }

  private static func append(_ segment: Substring, _ pen: Pen, to result: inout AttributedString) {
    guard !segment.isEmpty else { return }
    var piece = AttributedString(segment)
    if pen != Pen() {
      let foreground = pen.dim ? (pen.foreground?.opacity(0.6) ?? basic(8)) : pen.foreground
      piece.swiftUI.foregroundColor = foreground
      piece.swiftUI.backgroundColor = pen.background?.opacity(0.25)
      var intent: InlinePresentationIntent = []
      if pen.bold { intent.insert(.stronglyEmphasized) }
      if pen.italic { intent.insert(.emphasized) }
      if !intent.isEmpty { piece.inlinePresentationIntent = intent }
      if pen.underline { piece.swiftUI.underlineStyle = .single }
      if pen.strike { piece.swiftUI.strikethroughStyle = .single }
    }
    result.append(piece)
  }
}
