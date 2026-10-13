// 多行输入框（包一层 NSTextView）：翻译原文、剪贴板的编辑正文 / 新建片段用它（备注是单行的 CommandTextField）。回车走 doCommandBy，
// 输入法组字期间由输入法消费、不会误提交。主输入框挂进窗口时设为 initialFirstResponder；
// 对话框里的输入框出现时抢焦点（给了 focusRequest 的不抢，等它变了才拿：新建片段先填名称、Tab 过来）、
// 消失时把焦点还给主输入框（焦点已在别的输入框里就不抢）。插入点和选中文字底色是
// 品牌粉（mac-overlay-panel §3）；onFocusChange：焦点进出时回调（外面的输入框底据此画 Whisker 焦点环）。
// 外面的输入框底不给它左右内边距、改由 horizontalInset 缩进文字：滚动区铺满框宽，滚动条贴框的右边（同翻译结果卡）。
// 便签（Notes/）也用它：快速记一条是提交模式，全部便签窗口和屏幕边缘那叠的正文是不提交模式——另给字的颜色
// （textColor，纸上的墨；给了它插入点也用它：强调色选黄时在柠檬色的纸上看不见）、字节上限（maxBytes：会超的那一次
// 输入拦下，提示音 + onOverflow，不截断）和一个认它用的标记（identifier：那叠里换一条便签时新旧两个正文框会同时在，
// 按便签的编号找该拿焦点的那个）。那叠里「该拿焦点的那条便签」的正文框还会在挂进窗口的那一刻自己拿焦点
// （takesFocusOnAppear；之后再要一次走 focusRequest）。

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SourceTextView: NSViewRepresentable {
  @Binding var text: String
  /// true：Enter 提交、Shift+Enter / ⌘Enter 换行；false：Enter 换行（编辑正文）
  var submitsOnEnter = true
  var fontSize: CGFloat = 14
  /// 文字离滚动区左右边的距离（NSTextView 的 textContainerInset.width，另有 lineFragmentPadding 5）：
  /// 外面框的左右内边距挪到这里，滚动条才贴框边
  var horizontalInset: CGFloat = 2
  var isDialogField = false
  /// 对话框里第二个输入框：出现时不抢焦点，这个数变大一次就拿一次焦点（nil = 照常出现就抢）。
  /// 建出来时带着的那个数不算一次（只认之后的变化）
  var focusRequest: Int?
  /// 挂进窗口的那一刻就拿焦点（不是对话框的输入框也拿；窗口不必是 key）：屏幕边缘那叠里刚打开的那条便签的正文
  var takesFocusOnAppear = false
  /// 字的颜色；nil = 系统的文字色。给了的话插入点也用它（不给是强调色）
  var textColor: NSColor?
  /// 文本框的 identifier（按它在视图树里认这一个；nil = 不标）
  var identifier: String?
  /// 正文最多多少字节（UTF-8）；nil = 不限。会超的那一次输入不进（提示音、调 onOverflow），已有的字不动
  var maxBytes: Int?
  var onOverflow: () -> Void = {}
  var onCancel: (() -> Void)?
  var onSubmit: () -> Void = {}
  /// 焦点进出（画焦点环用）
  var onFocusChange: ((Bool) -> Void)?
  /// Tab / ⇧Tab：给了就交给它（快速记一条：去标题框），不给照常是输入一个制表符。
  /// 放在最后：排在 onSubmit 前面的话，别处写在末尾的那个提交闭包会被编译器配给它
  var onTab: (() -> Void)?

  func makeNSView(context: Context) -> FocusScrollView {
    let textView = FocusTextView(frame: .zero)
    textView.onFocusChange = onFocusChange
    textView.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .systemFont(ofSize: fontSize)
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: horizontalInset, height: 6)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.delegate = context.coordinator
    context.coordinator.focusRequest = focusRequest ?? 0
    let scroll = FocusScrollView()
    scroll.isDialogField = isDialogField
    scroll.grabsFocusOnAppear = focusRequest == nil
    scroll.takesFocusOnAppear = takesFocusOnAppear
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = textView
    return scroll
  }

  func updateNSView(_ scroll: FocusScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scroll.documentView as? FocusTextView else { return }
    textView.onFocusChange = onFocusChange
    if let request = focusRequest, request != context.coordinator.focusRequest {
      context.coordinator.focusRequest = request
      textView.window?.makeFirstResponder(textView)
    }
    if textView.string != text {
      textView.string = text
      context.coordinator.committed = text
    }
    if textView.font?.pointSize != fontSize { textView.font = .systemFont(ofSize: fontSize) }
    if let textColor, textView.textColor != textColor { textView.textColor = textColor }
    // 不露系统蓝：插入点强调色（纸上的输入框给了墨色就用墨色），选中文字底色强调色 0.28（普通 NSTextView 不是共用的
    // 字段编辑器；在这里设，设置里换了强调色也跟着变）
    textView.insertionPointColor = textColor ?? NSColor(Style.brand)
    textView.selectedTextAttributes = [
      .backgroundColor: NSColor(Style.brand).withAlphaComponent(0.28)
    ]
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  /// 把 current 里 range 那一段换成 replacement 之后会不会超过 maxBytes（纯函数，UTF-8 字节；range 是 UTF-16 的）。
  /// 没让正文变长的改动（删除、换成更短的）永远不算：正文不知怎么已经超了的时候，得删得动
  nonisolated static func overflows(
    _ current: String, replacing range: NSRange, with replacement: String, maxBytes: Int
  ) -> Bool {
    let removed = Range(range, in: current).map { current[$0].utf8.count } ?? 0
    let added = replacement.utf8.count
    return added > removed && current.utf8.count - removed + added > maxBytes
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SourceTextView
    /// 上次处理过的 focusRequest（建出来时带着的那个数，没给就是 0）
    var focusRequest = 0
    /// 有字节上限时：最近一次没在组字、也没超上限的全文（输入法确认之后超了就退回它）；nil = 还没打过字，用外面那份
    var committed: String?
    init(parent: SourceTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      guard let maxBytes = parent.maxBytes else {
        parent.text = textView.string
        return
      }
      let composing = textView.hasMarkedText()
      if textView.string.utf8.count > maxBytes {
        // 组字中超了：先不往外写（外面那份停在没超的样子），等确认
        guard !composing else { return }
        // 输入法确认的那一下 shouldChangeTextIn 拦不了（见下）：退回组字之前的样子。
        // ponytail: 整段换回去会清掉这个框的撤销栈、光标到末尾；只有贴着上限用输入法打字才走到这里，真碰上再细做
        textView.string = committed ?? parent.text
        textView.undoManager?.removeAllActions()
        overflowed()
      } else if !composing {
        committed = textView.string
      }
      parent.text = textView.string
    }

    /// 会让正文超过 maxBytes 的那一次输入（打字、粘贴、拖进来）不进。输入法还在组字时不判断（拦了会打断组字），
    /// 确认之后由 textDidChange 兜着
    func textView(
      _ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?
    ) -> Bool {
      guard let maxBytes = parent.maxBytes, let replacement = replacementString,
        !textView.hasMarkedText(),
        SourceTextView.overflows(
          textView.string, replacing: range, with: replacement, maxBytes: maxBytes)
      else { return true }
      overflowed()
      return false
    }

    private func overflowed() {
      NSSound.beep()
      parent.onOverflow()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard parent.submitsOnEnter, !flags.contains(.shift), !flags.contains(.command) else {
          return false
        }
        parent.onSubmit()
        return true
      // ⌘↩ 系统发的是 noop:（不是 insertNewline:）：提交模式下当换行用
      case Selector(("noop:")):
        guard parent.submitsOnEnter, let event = NSApp.currentEvent,
          [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)),
          event.modifierFlags.contains(.command)
        else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
      case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
        guard let onTab = parent.onTab else { return false }
        onTab()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        if let onCancel = parent.onCancel {
          onCancel()
        } else {
          textView.window?.cancelOperation(nil)
        }
        return true
      default:
        return false
      }
    }
  }

  final class FocusTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    /// 鼠标底下不是这个输入框（被浮在上面的菜单、卡片盖住了）：别把光标设成 I 形。文本视图不知道自己被盖住，
    /// 鼠标在它的范围里一动它就设 I 形——盖在便签正文上的「⋯」菜单上因此是输入框的光标（2026-10-13 用户报）
    override func mouseMoved(with event: NSEvent) {
      if isCovered(at: event.locationInWindow) {
        NSCursor.arrow.set()
      } else {
        super.mouseMoved(with: event)
      }
    }

    override func cursorUpdate(with event: NSEvent) {
      if isCovered(at: event.locationInWindow) {
        NSCursor.arrow.set()
      } else {
        super.cursorUpdate(with: event)
      }
    }

    /// 窗口里这一点上最上面的视图是不是别人的（SwiftUI 画在它上面的内容点到的是宿主视图，不是它）
    private func isCovered(at point: NSPoint) -> Bool {
      guard let content = window?.contentView else { return false }
      let local = content.superview?.convert(point, from: nil) ?? point
      guard let hit = content.hitTest(local) else { return false }
      return hit !== self && !hit.isDescendant(of: self)
    }

    override func becomeFirstResponder() -> Bool {
      defer { reportFocus() }
      return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
      defer { reportFocus() }
      return super.resignFirstResponder()
    }

    /// 晚一拍（下一轮 run loop）、按那时的第一响应者报（焦点常在 SwiftUI 更新中途变，当场改状态会出警告）
    private func reportFocus() {
      if onFocusChange != nil { perform(#selector(reportFocusNow), with: nil, afterDelay: 0) }
    }

    @objc private func reportFocusNow() {
      onFocusChange?(window?.firstResponder === self)
    }
  }

  final class FocusScrollView: NSScrollView {
    var isDialogField = false
    var grabsFocusOnAppear = true
    var takesFocusOnAppear = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if isDialogField {
        if grabsFocusOnAppear { window?.makeFirstResponder(documentView) }
      } else {
        window?.initialFirstResponder = documentView
        if takesFocusOnAppear { window?.makeFirstResponder(documentView) }
      }
    }

    /// 消失时还焦点，但焦点已经在别的输入框里（新弹出的对话框、已经还给主输入框）就不抢回来
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if isDialogField, newWindow == nil, let window,
        !(window.firstResponder is NSText) || window.firstResponder === documentView
      {
        window.makeFirstResponder(window.initialFirstResponder)
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
