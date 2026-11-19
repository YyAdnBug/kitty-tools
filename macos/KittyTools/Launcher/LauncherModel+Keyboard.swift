// 启动器的键盘（第五轮体检 H1 从 LauncherModel.swift 拆出）：输入框交过来的命令和 ⌘ 键、⌘↩、复制的几种格式、上下选。

import AppKit
import Carbon.HIToolbox
import SwiftUI

extension LauncherModel {
  // MARK: 键盘

  func handleCommand(_ selector: Selector) -> Bool {
    if showsActions { return handleMenuCommand(selector) }
    if review != nil { return handleReviewCommand(selector) }
    if output != nil { return handleOutputCommand(selector) }
    switch selector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1)
    case #selector(NSResponder.moveDown(_:)): move(by: 1)
    // ⌥↩ 来的是 insertNewlineIgnoringFieldEditor:、⌃↩ 是 insertLineBreak:；⌃O 这类别的键绑定也会发这两个，
    // 所以要确认真是回车键，再按当时按住的修饰键分（别的键绑定吞掉，不做事）
    case #selector(NSResponder.insertNewline(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey, let event = NSApp.currentEvent else { return true }
      if event.modifierFlags.contains(.option) {
        searchInFinder()
      } else if event.modifierFlags.contains(.control) {
        searchWeb()
      } else if let selectedItem {
        execute(selectedItem)
      }
    case #selector(NSResponder.insertTab(_:)):
      complete()  // 没得补也吞掉，不让焦点跳到别的控件
    // ⇧Tab：路径模式里回到上一级；别处吞掉（同 Tab，不让焦点跳走）
    case #selector(NSResponder.insertBacktab(_:)):
      if pathRequest != nil { goUpPath() }
    // →：光标在搜索词末尾、有选中项时打开动作菜单（同剪贴板），否则照常往右移光标
    case #selector(NSResponder.moveRight(_:))
    where selectedItem != nil && Self.caretAtEnd(of: query):
      toggleActions()
    case #selector(NSResponder.cancelOperation(_:)):
      forgotten = nil
      if isQuickLooking {
        toggleQuickLook()  // 先缩回预览
      } else if armed != nil {
        armed = nil  // 先撤掉上膛，再清空搜索
      } else {
        guard !query.isEmpty else { return false }  // 没有查询：交给窗口关闭
        query = ""
      }
    default: return false
    }
    return true
  }

  /// 看全文 / 输出那一页的 ↑↓、PageUp / PageDown：滚正文（是这几个键就接了，返回 true）
  private func scrollsPage(_ selector: Selector) -> Bool {
    let step: Int
    switch selector {
    case #selector(NSResponder.moveUp(_:)): step = -1
    case #selector(NSResponder.moveDown(_:)): step = 1
    case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): step = -2
    case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): step = 2
    default: return false
    }
    pageScroll = PageScroll(step: step, tick: pageScroll.tick + 1)
    return true
  }

  /// 看脚本全文那一页：↩ 运行、Esc 回去，↑↓ / PageUp / PageDown 滚正文，打字照常（会回到结果）
  private func handleReviewCommand(_ selector: Selector) -> Bool {
    switch selector {
    // 按住 ↩ 的自动连发不算：打开这一页的那一下连发过来不能直接放行
    case #selector(NSResponder.insertNewline(_:)):
      if Style.isReturnKey, !Style.isKeyRepeat { approveReview() }
    case #selector(NSResponder.cancelOperation(_:)): cancelReview()
    case _ where scrollsPage(selector): break
    case #selector(NSResponder.insertTab(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      break
    default: return false
    }
    return true
  }

  /// 全文输出那一页：↩ 粘贴、Esc 返回（还在跑就停掉），↑↓ / PageUp / PageDown 滚正文，打字照常（会回到结果）
  private func handleOutputCommand(_ selector: Selector) -> Bool {
    switch selector {
    // 按住 ↩ 的自动连发不算：跑得快的脚本跑完时连发过来的那一下不能直接粘贴出去
    case #selector(NSResponder.insertNewline(_:)):
      if Style.isReturnKey, !Style.isKeyRepeat { pasteOutput() }
    case #selector(NSResponder.cancelOperation(_:)): closeOutput()
    case _ where scrollsPage(selector): break
    case #selector(NSResponder.insertTab(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      break
    default: return false
    }
    return true
  }

  /// 搜索框的光标在最后（没有选中文字）；拿不到字段编辑器时（单测）看有没有字（同剪贴板）
  private static func caretAtEnd(of text: String) -> Bool {
    guard let editor = NSApp.currentEvent?.window?.firstResponder as? NSTextView,
      editor.isFieldEditor
    else { return text.isEmpty }
    let selection = editor.selectedRange()
    return selection.length == 0 && selection.location == (editor.string as NSString).length
  }

  /// 动作菜单开着（和剪贴板一致）：↑↓ 选、↩ 执行、Esc 只关菜单；菜单里标着的 ⇥ ⌥↩ ⌃↩ 和 ⌘ 键一样先关菜单再照常做，
  /// ⌃O 这类也发换行命令的别的键吞掉（不往过滤框里插换行），其余（左右移光标、删字）交还输入框
  private func handleMenuCommand(_ selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.moveUp(_:)): moveAction(by: -1)
    case #selector(NSResponder.moveDown(_:)): moveAction(by: 1)
    case #selector(NSResponder.insertNewline(_:)): runSelectedAction()
    case #selector(NSResponder.cancelOperation(_:)): showsActions = false
    case #selector(NSResponder.moveLeft(_:)) where actionQuery.isEmpty: showsActions = false
    case #selector(NSResponder.insertTab(_:)):
      showsActions = false
      complete()
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      guard Style.isReturnKey else { break }
      showsActions = false
      return handleCommand(selector)
    default: return false
    }
    return true
  }

  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    // 不看大写锁定、fn 和数字键盘标志（方向键带着后两个），和 OverlayPanel 的 ⌘W 同一套判断
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    // 字母、标点按打出来的字认（E2）
    let key = event.typedKeyCode
    // 看脚本全文那一页：⌘1–9、⌘Y、⌘D 这些对着藏在后面的行的键都不做，编辑搜索框的（剪切、复制、粘贴、全选、撤销）照常
    if review != nil {
      let editing = [kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_A, kVK_ANSI_Z]
      return !(modifiers == .command && editing.contains(key))
        && !(modifiers == [.command, .shift] && key == kVK_ANSI_Z)
    }
    // 全文输出那一页：⌘C 全部复制（搜索框里选着字时交还输入框）、⌘R 重跑
    if output != nil {
      guard modifiers == .command else { return false }
      if key == kVK_ANSI_R {
        // 按住不放的自动连发不算：一秒起十几个进程（第 1 批评审）
        if !event.isARepeat { rerunOutput() }
        return true
      }
      guard key == kVK_ANSI_C, !Self.fieldHasSelection(event) else { return false }
      copyOutput()
      return true
    }
    let handled: Bool
    switch modifiers {
    case .command where key == kVK_ANSI_K:
      toggleActions()
      return true
    case .command: handled = handleCommandKey(event)
    case [.command, .option] where key == kVK_UpArrow || key == kVK_DownArrow:
      handled = moveFavorite(by: key == kVK_UpArrow ? -1 : 1)
    case [.command, .shift] where key == kVK_ANSI_C:
      guard let item = selectedItem, isWebLink(item) || isPathRow(item),
        !Self.fieldHasSelection(event)
      else {
        return false
      }
      if isPathRow(item) { copyFile(item) } else { copy(item, .markdown) }
      handled = true
    case [.command, .option] where key == kVK_ANSI_C:
      guard let item = selectedItem, isPathRow(item) else { return false }
      copyShellPath(item)
      handled = true
    default: return false
    }
    // 做了就收起动作菜单；没做的（过滤框里的复制、粘贴）菜单留着
    if handled { showsActions = false }
    return handled
  }

  private static func fieldHasSelection(_ event: NSEvent) -> Bool {
    ((event.window?.firstResponder as? NSTextView)?.selectedRange().length ?? 0) > 0
  }

  private func handleCommandKey(_ event: NSEvent) -> Bool {
    switch event.typedKeyCode {
    case kVK_Return:
      if let item = selectedItem { commandReturn(item) }
    // 「常用」里 ⌘⌫：忘掉这一项（有查询、或 ⌘K 过滤框里有字时 ⌘⌫ 照常删到行首）；收藏上没有这个动作，响提示音
    case kVK_Delete where isShowingRecent && (!showsActions || actionQuery.isEmpty):
      if let item = selectedItem, isCommon(item) { forget(item) } else { NSSound.beep() }
    // ⌘Z：撤销刚才的移除；没有可撤的、或 ⌘K 过滤框里有字时交还输入框自己的撤销
    case kVK_ANSI_Z
    where query.isEmpty && forgotten != nil && (!showsActions || actionQuery.isEmpty):
      undoForget()
    case kVK_ANSI_C where !Self.fieldHasSelection(event):
      guard let item = selectedItem, copyTitle(for: item) != nil else { return false }
      copy(item)
    case kVK_ANSI_D:
      guard let item = selectedItem, canFavorite(item) else { return false }
      toggleFavorite(item)
    case kVK_ANSI_Y:
      toggleQuickLook()
    case kVK_ANSI_T:
      guard let item = selectedItem, isPathRow(item) else { return false }
      openInTerminal(item)
    case kVK_ANSI_E:
      guard let item = selectedItem, let script = script(of: item) else { return false }
      edit(script)
    case kVK_ANSI_Comma:
      close()
      openSettings()
    default:
      guard let digit = HotKey.digitKeys.firstIndex(of: Int(event.keyCode)) else { return false }
      let row = shortcutBase + digit
      // 列表脚本正在重跑时的结果行：⌘N 会落到新结果的第一条上，不执行
      if row < results.count, !isPending(results[row]) {
        execute(results[row])
      } else if row < results.count {
        NSSound.beep()
      }
    }
    return true
  }

  /// ⌘↩：App / 文件在访达中显示（find 搜到的文件反过来是打开），计算结果只复制，网址用第二个浏览器打开
  /// （没有就提示音，体检 D7）
  func commandReturn(_ item: LauncherItem) {
    if let request = commandRequest, [.app, .process].contains(item.kind) {
      let verb = rowVerb(item, in: request)
      if verb == .kill || (verb != .forcequit && item.target != SystemCommands.finderPath) {
        runTarget(item, verb, commandKey: true)
      }
      return
    }
    if isWebLink(item) {
      guard let browser = otherBrowsers.first, let url = URL(string: item.target) else {
        return NSSound.beep()
      }
      return open(url, item.kind == .url ? item : nil, with: browser)
    }
    switch item.kind {
    case .app, .path:
      if revealsOnReturn(item) { return open(URL(filePath: item.target), item) }
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    case .scriptResult where item.payload != nil:
      // 文件结果在访达中显示（同文件行）；别的只复制 ↩ 会打开 / 粘贴的那个（text.copy 归 ⌘C）
      if isPending(item) { return NSSound.beep() }
      guard case .file(let path) = item.opens else {
        var plain = item
        plain.copyText = nil
        return copy(plain)
      }
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    case .calculation where item.payload != nil, .ip where item.payload != nil:
      copy(item)
    case .reminder where !item.target.isEmpty:
      close()
      openReminder(item.target)
    case .script:
      close()
      NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.target)])
    default:
      NSSound.beep()  // 以前吞掉这个键、什么都不响
    }
  }

  enum CopyFormat {
    /// 路径 / 网址 / 计算结果（⌘C）
    case value
    /// [标题](网址)（⇧⌘C）
    case markdown
    case title
    /// 计算结果 ⌘K 里的「复制原始数字」「复制十六进制」…（体检 D11）
    case calculation(Calculator.Copy)
  }

  /// ⌘C：复制路径 / 网址 / 计算结果（⌘↩ 的计算结果也走这里）；网址另有 Markdown 链接、标题。面板同时收起，用刘海说
  /// 复制了什么；这些是本 App 给出的新文字，同时记进剪贴板历史（mac-native §5）
  func copy(_ item: LauncherItem, _ format: CopyFormat = .value) {
    // 列表脚本正在按新输入重跑：看得见的是上一次的结果，不拷它（同 ↩ 等结果的那一处，第三轮评审）
    if isPending(item) { return NSSound.beep() }
    rememberCurrencies(item)
    let text: String
    let title: LocalizedStringResource?
    switch format {
    // 列表结果：text.copy 写了的复制它，写了 url / path 的复制网址 / 路径（第三轮 B1 B2）
    case .value:
      (text, title) = (
        item.copyText ?? item.opens?.text ?? item.payload ?? item.target, copyTitle(for: item)
      )
    case .markdown:
      (text, title) = (Self.markdownLink(title: item.title, url: item.target), "复制为 Markdown 链接")
    case .title: (text, title) = (item.title, "复制标题")
    case .calculation(let copy): (text, title) = (copy.text, copy.title)
    }
    Paster.write(string: text, record: true)
    close()
    guard let title else { return }
    let isPath = (item.kind == .app || item.kind == .path) && copyTitle(for: item) == title
    island?.show(
      Self.copied(title),
      detail: isPath
        ? "\((text as NSString).abbreviatingWithTildeInPath)" : "\(Island.excerpt(text))")
  }

  /// 复制完岛上那一句：「复制路径」→「已复制路径」（英文 Path Copied）。认的是复制项的中文原文；没列到的说「已复制」
  static func copied(_ title: LocalizedStringResource) -> LocalizedStringResource {
    switch title.key {
    case "复制路径": "已复制路径"
    case "复制网址": "已复制网址"
    case "复制结果": "已复制结果"
    case "复制地址": "已复制地址"
    case "复制为 Markdown 链接": "已复制为 Markdown 链接"
    case "复制标题": "已复制标题"
    case "复制原始数字": "已复制原始数字"
    case "复制汇率": "已复制汇率"
    case "复制十进制": "已复制十进制"
    case "复制十六进制": "已复制十六进制"
    case "复制二进制": "已复制二进制"
    default: "已复制"
    }
  }

  /// [标题](网址)：标题里的方括号、网址里的空格和右括号转义，粘进 Markdown 不断链
  static func markdownLink(title: String, url: String) -> String {
    let title = title.replacing("[", with: "\\[").replacing("]", with: "\\]")
    let url = url.replacing(" ", with: "%20").replacing(")", with: "%29")
    return "[\(title)](\(url))"
  }

  private func move(by offset: Int) {
    guard !results.isEmpty else { return }
    armed = nil
    forgotten = nil
    selectionMotion = Style.isKeyRepeat ? .instant : .snap
    selection = (selection + offset + results.count) % results.count
    userMovedSelection = true
    // 焦点一直在搜索框，行上的「已选中」读屏看不到：说出选中了什么（A1）
    if let item = selectedItem { Island.announceSettled(item.title, item.kindTitle) }
  }
}
