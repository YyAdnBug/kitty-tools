// 启动器搜索框的输入法组字（2026-11-17，用户转来「热键打开启动器后少了第一个字母」）：组字中面板因为别的事更新时，
// 组着的拼音不能被绑定里的旧字盖掉（同 issue #30，修法在 CommandTextField.updateNSView：组字中只认外面真改了的字）。
// 用真的面板和视图（屏外、不当 key），走 setMarkedText / insertText，不发系统事件、不切输入法。

import AppKit
import SwiftUI
import Testing

@testable import KittyTools

struct LauncherComposingTests {
  /// issue #36：macOS 26 起系统的「填充验证码」菜单默认挂在所有输入框上（启动器的搜索框打不进字、回车确认不了）。
  /// 靠 Info.plist 退出：只给标了 .oneTimeCode 的框弹，Kitty 没有这种框。测试宿主就是 Dev 版，读的是打进包里的那份
  @Test func oneTimeCodeAutoFillOnlyForMarkedFields() {
    let key = "NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac"
    #expect(Bundle.main.object(forInfoDictionaryKey: key) as? Bool == true)
  }

  private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
    guard let view else { return nil }
    return (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
  }

  /// 搜索框自己不报「在组字」、不为组字重画，碰到它的是面板别的更新：改之前组字中按了 ⌥（选中行的副标题跟着换）每次都挂，
  /// 写 stringValue 先把拼音当字母确认掉（query 变成 w，接着选字打成「w微」）；呼出后不等 SwiftUI 更新就开始组字（热键和
  /// 第一个键在队列里挨着）实测挂过一次、不稳定。另锁住组字中呼出时在后台重读的浏览历史读完、重搜出新的一行（改之前
  /// 这一处实测没挂，一起锁住）。
  /// async：重读历史的 Task 要主线程空下来才跑（同步测试里转 run loop 跑不到它）
  @Test func keepsComposingWhilePanelUpdates() async throws {
    let apps = ["/System/Applications/Calculator.app", "/System/Applications/Notes.app"]
      .map { AppCatalog.item(path: $0) }
    let model = LauncherModel(usage: try LauncherUsage(db: Database(path: ":memory:")), apps: apps)
    var reloads = 0
    var pages: [LauncherItem] = []
    model.historyItems = { pages }
    // 每次呼出都进程外重读浏览历史：比打字慢一点，读完换上新的一页（刚在浏览器里看过）
    model.refreshHistory = {
      try? await Task.sleep(for: .milliseconds(150))
      reloads += 1
      pages = BrowserHistory.items([
        .init(url: "https://cal.example.com/\(reloads)", title: "cal \(reloads)", visitedAt: .now)
      ])
      return true
    }
    let panel = OverlayPanel(
      size: NSSize(width: 680, height: 400), topAnchored: true, autoHide: .clickOutside,
      isPinned: { false }, content: LauncherPanelView(model: model))
    model.resize = { [unowned panel] in panel.setContentHeight($0) }
    let none = NSRange(location: NSNotFound, length: 0)
    func mark(_ text: String, in view: NSTextView) {
      view.setMarkedText(
        text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
        replacementRange: none)
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
    // 呼出、拿到焦点，不等 SwiftUI 更新就开始组 w；再按住 ⌥
    model.prepareForShow()
    panel.contentView?.layoutSubtreeIfNeeded()
    let field = try #require(find(CommandTextField.FocusField.self, in: panel.contentView))
    #expect(panel.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    mark("w", in: editor)
    await settle()
    #expect(editor.hasMarkedText() && editor.string == "w" && model.query == "")
    model.alternate = .option
    await settle()
    model.alternate = .none
    await settle()
    #expect(editor.hasMarkedText() && editor.string == "w" && model.query == "")
    editor.insertText("微", replacementRange: none)
    await settle()
    #expect(model.query == "微")
    // 收起再呼出（又在后台重读历史），打了 cal 、接着组下一个词：组字中历史读完、重搜，结果多了刚读到的那一页
    editor.selectAll(nil)
    editor.insertText("", replacementRange: none)
    model.didHide()
    model.prepareForShow()
    editor.insertText("cal ", replacementRange: none)
    // 真打字每个键是 run loop 的一轮，两个键之间 SwiftUI 把 cal 推给了输入框；不等这一下，组字时那次更新就成了「外面改了字」
    try? await Task.sleep(for: .milliseconds(30))
    mark("w", in: editor)
    #expect(!model.results.contains { $0.title == "cal 2" })
    await settle()
    #expect(reloads == 2 && model.results.contains { $0.title == "cal 2" })
    #expect(editor.hasMarkedText() && editor.string == "cal w" && model.query == "cal ")
    editor.insertText("微", replacementRange: none)
    await settle()
    #expect(model.query == "cal 微")
  }
}
