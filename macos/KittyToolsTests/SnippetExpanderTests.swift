// 片段展开（2026-11-22）第 2 批：认关键词的那一小段（KeyBuffer：哪些键清空、⌫、词首、最长的那个、认出来就清空、只留最长关键词
// 那么多个字）、关键词集合只算文字片段、设置页的橙字。实机的拦截不在这里建（看得到真键盘）；按需的 liveTapKind 只建一下拦截、
// 看测试宿主（= Dev 版的授权）能建哪一种，马上撤掉，不发键：TEST_RUNNER_KITTY_LIVE_SNIPPET_TAP=1

import Carbon.HIToolbox
import Foundation
import Testing

@testable import KittyTools

struct SnippetExpanderTests {
  private func type(_ text: String, into buffer: inout KeyBuffer, keywords: Set<String>) -> [String]
  {
    text.compactMap { buffer.press(.characters(String($0)), keywords: keywords) }
  }

  @Test func classifiesKeys() {
    #expect(KeyBuffer.classify(code: kVK_ANSI_A, flags: [], characters: "a") == .characters("a"))
    #expect(
      KeyBuffer.classify(code: kVK_ANSI_A, flags: .maskShift, characters: "A") == .characters("A"))
    // 带 ⌥ 出的字照样算字
    #expect(
      KeyBuffer.classify(code: kVK_ANSI_A, flags: .maskAlternate, characters: "å")
        == .characters("å"))
    #expect(KeyBuffer.classify(code: kVK_ANSI_V, flags: .maskCommand, characters: "v") == .reset)
    #expect(
      KeyBuffer.classify(code: kVK_ANSI_A, flags: .maskControl, characters: "\u{1}") == .reset)
    #expect(KeyBuffer.classify(code: kVK_Delete, flags: [], characters: "\u{7F}") == .backspace)
    // ⌥⌫ 删一个词：不知道删了几个字，清空
    #expect(
      KeyBuffer.classify(code: kVK_Delete, flags: .maskAlternate, characters: "\u{7F}") == .reset)
    for code in [kVK_LeftArrow, kVK_Return, kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_F5] {
      #expect(KeyBuffer.classify(code: code, flags: [], characters: "") == .reset, "\(code)")
    }
    // 死键的第一下（布局没给字）：不动
    #expect(KeyBuffer.classify(code: kVK_ANSI_E, flags: .maskAlternate, characters: "") == .ignore)
  }

  @Test func matchesAtWordStartOnly() {
    let keywords: Set<String> = [";mail", "omyx", "ail"]
    var buffer = KeyBuffer()
    #expect(type("hi ;mail", into: &buffer, keywords: keywords) == [";mail"])
    // 认出来就清空：接着打不再认
    #expect(buffer.text.isEmpty)
    #expect(type("roomyx", into: &buffer, keywords: keywords).isEmpty)
    buffer.reset()
    #expect(type("omyx", into: &buffer, keywords: keywords) == ["omyx"])
    // 前面是标点、空格、汉字以外的东西（这里是 ;）算词首；字母、数字不算
    #expect(type("a;mail", into: &buffer, keywords: keywords) == [])
    buffer.reset()
    #expect(type("1omyx", into: &buffer, keywords: keywords) == [])
    buffer.reset()
    #expect(type("(omyx", into: &buffer, keywords: keywords) == ["omyx"])
  }

  @Test func backspaceAndResets() {
    let keywords: Set<String> = [";mail"]
    var buffer = KeyBuffer()
    #expect(type(";maik", into: &buffer, keywords: keywords).isEmpty)
    #expect(buffer.press(.backspace, keywords: keywords) == nil)
    #expect(type("l", into: &buffer, keywords: keywords) == [";mail"])
    #expect(type(";ma", into: &buffer, keywords: keywords).isEmpty)
    #expect(buffer.press(.reset, keywords: keywords) == nil)
    #expect(type("il", into: &buffer, keywords: keywords).isEmpty)
    // ⌫ 打到空了照样没事
    buffer.reset()
    #expect(buffer.press(.backspace, keywords: keywords) == nil)
  }

  @Test func prefersLongestAndKeepsCapacity() {
    // 两个都在末尾、都在词首：取长的
    var buffer = KeyBuffer()
    #expect(type(" ;mail", into: &buffer, keywords: [";mail", "mail"]) == [";mail"])
    buffer.reset()
    // 短的那个前面是字母、不在词首：只有长的
    #expect(type(" xmail", into: &buffer, keywords: ["xmail", "mail"]) == ["xmail"])
    buffer.reset()
    #expect(type(";sig", into: &buffer, keywords: [";sig", ";sig2"]) == [";sig"])
    // 拦截按最长的关键词 + 1 留字：最长的那个前面一个字还在，词首照样认（只留 4 个的话 x;sig 会被当成词首）
    buffer = KeyBuffer(capacity: 5)
    #expect(type("x;sig", into: &buffer, keywords: [";sig"]).isEmpty)
    #expect(type(" ;sig", into: &buffer, keywords: [";sig"]) == [";sig"])
    // 只留 capacity 个字
    buffer = KeyBuffer(capacity: 4)
    _ = type("abcdefgh", into: &buffer, keywords: [])
    #expect(buffer.text == "efgh")
  }

  @Test func keywordsComeFromTextSnippetsOnly() {
    var snippet = ClipItem(kind: .text)
    snippet.isSnippet = true
    snippet.keyword = ";a1"
    var removed = snippet
    removed.id = UUID()
    removed.isSnippet = false
    removed.keyword = ";b1"
    var plain = ClipItem(kind: .text)
    plain.keyword = ";c1"
    #expect(SnippetExpander.keywords(in: [snippet, removed, plain]) == [";a1"])
  }

  /// 便签正文里：插入点紧前面是刚打的关键词才换（UTF-16 的范围；有选中的、前面不是它的不换）
  @Test func typedRangeInNotes() {
    #expect(
      SnippetExpander.typedRange(
        of: ";mail", in: "你好 ;mail", selection: NSRange(location: 8, length: 0))
        == NSRange(location: 3, length: 5))
    #expect(
      SnippetExpander.typedRange(
        of: ";mail", in: "你好 ;mail", selection: NSRange(location: 7, length: 0))
        == nil)
    #expect(
      SnippetExpander.typedRange(
        of: ";mail", in: ";mail", selection: NSRange(location: 0, length: 5))
        == nil)
    #expect(
      SnippetExpander.typedRange(
        of: ";mail", in: "mail", selection: NSRange(location: 4, length: 0))
        == nil)
  }

  @Test func settingsWarnings() {
    #expect(SnippetExpandSection.warning(secure: nil) == nil)
    #expect(SnippetExpandSection.warning(secure: nil, failed: true)?.contains("听不到键盘") == true)
    let warning = SnippetExpandSection.warning(
      secure: .init(holder: "终端", bundleID: "com.apple.Terminal"))
    #expect(warning?.contains("「终端」开着安全输入") == true)
    #expect(warning?.contains("安全键盘输入") == true)
    #expect(
      SnippetExpandSection.warning(secure: nil, duplicated: true)?.contains("重复")
        == true)
  }

  /// 按需：测试宿主（Dev 版的授权）建不建得起只听的拦截（只有辅助功能、没有输入监控时可能不行），建了马上撤
  @Test(.enabled(if: ProcessInfo.processInfo.environment["KITTY_LIVE_SNIPPET_TAP"] == "1"))
  func liveTapKind() {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
    let listen = CGEvent.tapCreate(
      tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
      eventsOfInterest: mask, callback: callback, userInfo: nil)
    let active = CGEvent.tapCreate(
      tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: callback, userInfo: nil)
    print(
      "snippet-tap: AX \(AXIsProcessTrusted()) 输入监控 \(CGPreflightListenEventAccess()) 只听的 \(listen != nil) 不吞键的 \(active != nil)"
    )
    for port in [listen, active].compactMap({ $0 }) { CFMachPortInvalidate(port) }
    #expect(listen != nil || active != nil)
  }
}
