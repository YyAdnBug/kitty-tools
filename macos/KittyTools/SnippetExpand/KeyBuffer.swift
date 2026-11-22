// 片段展开认关键词的那一小段（纯状态，配单测；只在拦截线程上用）：最近打的字、哪些键让它清空、打完一个字时末尾是不是某个关键词。
// - 只留最长的关键词再多一个字（capacity），多了从前面丢；不存盘、不进日志
// - 打字：按键盘布局给的字（拦截读 keyboardGetUnicodeString）往后接；⌫ 去掉最后一个；空的（死键的第一下）不动
// - 清空：方向键、回车、Tab、Esc、⌦、Home / End / 翻页、F 键、带 ⌘ / ⌃ 的组合、控制字符，鼠标按下、换了收键的进程（KeywordTap 管）
// - 认：末尾正好是某个关键词，而且它前面一个字不是字母或数字（Q4 只在词首；清空过之后前面是什么不知道，算词首）；
//   几个都对得上时取最长的（;mail 和 ail 都是关键词、打 ;mail 时是 ;mail）。认出来之后清空，免得接着打又认一次

import Carbon.HIToolbox
import CoreGraphics
import Foundation

nonisolated struct KeyBuffer: Equatable {
  /// 留多少个字：最长的关键词再多一个（要看它前面那一个字是不是字母、数字，不然最长的那个永远算在词首）
  var capacity = SnippetKeyword.maxLength + 1
  private(set) var text = ""

  /// 一个按下的键怎么办
  enum Key: Equatable {
    /// 出字的键（布局给的字）
    case characters(String)
    case backspace
    /// 让前面的字作废：方向键、回车这类，带 ⌘ / ⌃ 的组合
    case reset
    /// 不管（死键的第一下、只按修饰键）
    case ignore
  }

  /// 按下的键分类：键码、修饰键、布局给的字
  static func classify(code: Int, flags: CGEventFlags, characters: String) -> Key {
    if !flags.intersection([.maskCommand, .maskControl]).isEmpty { return .reset }
    switch code {
    // ⌥⌫ 在 App 里删一个词：不知道删了几个字，清空
    case kVK_Delete: return flags.contains(.maskAlternate) ? .reset : .backspace
    case kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home,
      kVK_End, kVK_PageUp, kVK_PageDown, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
      kVK_Help:
      return .reset
    case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
      kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
      return .reset
    default: break
    }
    guard !characters.isEmpty else { return .ignore }
    if characters.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
      return .reset
    }
    return .characters(characters)
  }

  /// 按下一个键；打完一个字时末尾是某个关键词就给它（并清空），别的时候 nil
  mutating func press(_ key: Key, keywords: Set<String>) -> String? {
    switch key {
    case .characters(let characters):
      text += characters
      if text.count > capacity { text.removeFirst(text.count - capacity) }
      guard let keyword = match(keywords) else { return nil }
      text = ""
      return keyword
    case .backspace:
      if !text.isEmpty { text.removeLast() }
    case .reset:
      text = ""
    case .ignore:
      break
    }
    return nil
  }

  mutating func reset() { text = "" }

  /// 末尾是哪个关键词（在词首；几个都对得上取最长的）
  func match(_ keywords: Set<String>) -> String? {
    keywords.filter { keyword in
      guard text.hasSuffix(keyword) else { return false }
      guard let before = text.dropLast(keyword.count).last else { return true }
      return !(before.isLetter || before.isNumber)
    }
    .max { ($0.count, $0) < ($1.count, $1) }
  }
}
