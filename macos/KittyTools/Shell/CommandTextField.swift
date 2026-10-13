// 单行输入框（包一层 NSTextField）：方向键 / 回车 / Tab / ⇧Tab / ← → / ⌫ / Esc 走 doCommandBy（全部转给 onCommand，
// 返回 false 就交还字段编辑器照常处理）。输入法组字期间这些键由输入法消费、不会回调过来，所以不需要吞键 hack。
// 挂进窗口时把自己设为 initialFirstResponder，浮层显示时自动聚焦；拿到焦点时插入点和选中底色设成品牌粉
// （给了 textColor 的——便签纸上的标题框——插入点用那个颜色）。
// onFocusChange：焦点进出时回调（外面的输入框底据此画 Whisker 焦点环）。
// romanOnly：聚焦时只允许英文类输入法（系统自动切过去，离开后恢复）。
// maxLength：字数上限，超出的那次输入整段退回（提示音，不截断；输入法组字中不打断，确认后再判断）。
// focusRequest：面板里主输入框之外的第二个框（快速记一条的标题）——不登记成 initialFirstResponder（面板呼出时焦点不进它），
// 这个数每变一次拿一次焦点（同 SourceTextView.focusRequest，mac-overlay-panel §3）。

import AppKit
import SwiftUI

struct CommandTextField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  /// 面板里的对话框输入框：出现时抢焦点，消失时把焦点还给它之前的输入框（还在窗口里的话；否则是面板的主输入框）
  var isDialogField = false
  var fontSize: CGFloat = 14
  var weight: NSFont.Weight = .regular
  /// 字的颜色；nil = 系统的文字色（便签的标题框给纸上的墨色）
  var textColor: NSColor?
  /// 只用英文类输入法（启动器的「呼出时切英文输入法」）
  var romanOnly = false
  /// 字数上限（收藏夹名 24 字）；nil = 不限
  var maxLength: Int?
  /// 给了它：出现时不抢焦点、也不登记成面板呼出时聚焦的那个框，这个数变一次才拿一次焦点（建出来时带着的那个数不算）
  var focusRequest: Int?
  /// 返回 true 表示已处理（moveUp: / moveDown: / insertNewline: / cancelOperation: …）。
  /// 没处理的 cancelOperation: 交给窗口（浮层据此关闭）
  var onCommand: (Selector) -> Bool = { _ in false }
  /// 焦点进出（画焦点环用）
  var onFocusChange: ((Bool) -> Void)?

  func makeNSView(context: Context) -> FocusField {
    context.coordinator.focusRequest = focusRequest ?? 0
    let field = FocusField()
    field.isDialogField = isDialogField
    field.claimsInitialFocus = focusRequest == nil
    field.placeholderString = placeholder
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: fontSize, weight: weight)
    field.cell?.usesSingleLineMode = true
    field.cell?.lineBreakMode = .byTruncatingTail
    field.delegate = context.coordinator
    field.onFocusChange = onFocusChange
    return field
  }

  func updateNSView(_ field: FocusField, context: Context) {
    context.coordinator.parent = self
    field.onFocusChange = onFocusChange
    if let request = focusRequest, request != context.coordinator.focusRequest {
      context.coordinator.focusRequest = request
      field.window?.makeFirstResponder(field)
    }
    // 纸上的输入框（给了墨色）：插入点用墨色——强调色选黄时在柠檬色的纸上看不见。别的调用方不给，照旧是强调色
    field.caretColor = textColor
    // 读了 Style.brand：设置里换了强调色时这里会重跑，正在编辑的插入点和选中底色跟着换
    field.applyBrandColors(NSColor(Style.brand))
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if let textColor, field.textColor != textColor { field.textColor = textColor }
    if field.romanOnly != romanOnly {
      field.romanOnly = romanOnly
      field.applyInputSources()
    }
    guard field.stringValue != text else { return }
    field.stringValue = text
    // 程序改的文字（Tab 补全、清空）：光标放到末尾，接着打字
    if let editor = field.currentEditor() {
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: CommandTextField
    /// 上次处理过的 focusRequest（建出来时带着的那个数，没给就是 0）
    var focusRequest = 0
    init(parent: CommandTextField) { self.parent = parent }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      if let maxLength = parent.maxLength, field.stringValue.count > maxLength {
        // 输入法还在组字：先不动（改字会打断组字）；确认后仍超出就整段退回
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        field.stringValue = parent.text
        NSSound.beep()
        return
      }
      parent.text = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
    {
      if parent.onCommand(selector) { return true }
      if selector == #selector(NSResponder.cancelOperation(_:)) {
        control.window?.cancelOperation(nil)
        return true
      }
      return false
    }
  }

  final class FocusField: NSTextField {
    var isDialogField = false
    /// 不是对话框的输入框：挂进窗口时把自己登记成面板呼出时聚焦的那个（给了 focusRequest 的第二个框不登记）
    var claimsInitialFocus = true
    var romanOnly = false
    var onFocusChange: ((Bool) -> Void)?
    /// 插入点的颜色；nil = 强调色
    var caretColor: NSColor?
    /// 对话框输入框抢焦点前拿着焦点的输入框：消失时还给它（管理收藏夹里行内改名完回到下面的新建框）
    private weak var previousField: NSView?

    override func becomeFirstResponder() -> Bool {
      guard super.becomeFirstResponder() else { return false }
      applyInputSources()
      applyBrandColors()
      reportFocus()
      return true
    }

    /// 字段编辑器交出焦点（焦点去了别处）
    override func textDidEndEditing(_ notification: Notification) {
      super.textDidEndEditing(notification)
      reportFocus()
    }

    /// 晚一拍（下一轮 run loop）、按那时的第一响应者报：焦点常在 SwiftUI 插入 / 移除视图的更新中途变，当场改状态
    /// 会出警告；字段编辑器接手时 NSTextField 自己会先 resign，所以只认字段编辑器
    private func reportFocus() {
      if onFocusChange != nil { perform(#selector(reportFocusNow), with: nil, afterDelay: 0) }
    }

    @objc private func reportFocusNow() {
      let editor = currentEditor()
      onFocusChange?(editor != nil && window?.firstResponder === editor)
    }

    /// 插入点和选中文字底色用强调色（mac-overlay-panel §3）。字段编辑器是窗口共用的，别处可能改过，
    /// 所以每次拿到焦点都设一遍，不露系统蓝
    func applyBrandColors(_ brand: NSColor = NSColor(Style.brand)) {
      guard let editor = currentEditor() as? NSTextView else { return }
      editor.insertionPointColor = caretColor ?? brand
      editor.selectedTextAttributes = [.backgroundColor: brand.withAlphaComponent(0.28)]
    }

    /// 输入法限制挂在正在编辑的字段编辑器上（它是这个窗口共用的，所以关掉时要显式还原成不限制）
    func applyInputSources() {
      currentEditor()?.inputContext?.allowedInputSourceLocales =
        romanOnly ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if isDialogField {
        // 正在编辑的是字段编辑器，它的代理才是那个输入框
        let current = window?.firstResponder
        previousField = ((current as? NSTextView)?.delegate as? NSView) ?? (current as? NSView)
        window?.makeFirstResponder(self)
      } else if claimsInitialFocus {
        window?.initialFirstResponder = self
      }
    }

    /// 消失时还焦点，但焦点已经在别的输入框里（刚打开的新框、已经还给主输入框）就不抢回来
    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if isDialogField, newWindow == nil, let window,
        !(window.firstResponder is NSText) || window.firstResponder === currentEditor()
      {
        let previous = previousField.flatMap { $0.window === window && $0 !== self ? $0 : nil }
        window.makeFirstResponder(previous ?? window.initialFirstResponder)
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}
