// AppDelegate 里的翻译入口（第五轮体检 H1 从 AppDelegate.swift 拆出）：输入翻译、浮窗位置、便签里的选区、划词翻译、替换原文、划词翻译并替换、复制即译。

import AppKit
import SwiftUI

extension AppDelegate {
  /// 输入翻译（体检 A14）：热键是开关——浮窗开着且是 key 就收起；否则打开，保留上次的原文和结果、原文全选
  /// （直接打字就替换，⌫ 清空），上次收起时中断的卡片重跑。总在上次拖到的位置（不跟随鼠标）；「屏幕上方」时没拖过就放上方。
  /// 菜单栏、启动器同一条路
  func showInputTranslate() {
    if translatePanel.isVisible, translatePanel.isKeyWindow { return translatePanel.dismiss() }
    coordinator.resumeInput()
    translatePanel.present(atTop: Self.translatePosition == "top" && !translatePanel.hasUserFrame)
    (translatePanel.firstResponder as? NSTextView)?.selectAll(nil)
  }

  /// 翻译浮窗出现（划词、截图翻译、复制即译、剪贴板「翻译」）：设置 › 翻译「浮窗位置」是屏幕上方（默认，2026-10-29 用户要求）时
  /// 放在鼠标所在屏的上方正中（同启动器的位置），跟随鼠标时放在光标右下，上次位置时在上次拖到的地方（体检 A13）
  func presentTranslate(makingKey: Bool = true) {
    let position = Self.translatePosition
    translatePanel.present(
      makingKey: makingKey, anchor: position == "mouse" ? NSEvent.mouseLocation : nil,
      atTop: position == "top")
  }

  /// 「浮窗位置」：top（屏幕上方）/ mouse（跟随鼠标）/ last（上次位置）；认不出的值按默认的屏幕上方
  private static var translatePosition: String {
    let value = UserDefaults.standard.string(forKey: Prefs.translatePanelPosition)
    return value == "mouse" || value == "last" ? value! : "top"
  }

  /// 便签正文里选中的一段（第 8 批 R13）：划词翻译直接读它、替换回它，不走 AX、不发 ⌘C
  struct NoteSelection {
    weak var view: NoteTextView?
    /// 读选区时这个正文框是哪条便签（`NoteTextView.identifier`）：全部便签窗口和便签墙的编辑卡换一条便签时用的是
    /// 同一个正文框，只比范围里的字会把译文写进另一条同样开头的便签
    var identifier: NSUserInterfaceItemIdentifier?
    var range: NSRange
    /// 选中的**存的形式**（带任务方框、Markdown 标记、图片令牌）：替换前比它有没有变
    var raw: String
    /// 给翻译看的（标记去掉、图片成「[图片]」）
    var plain: String

    /// 用译文换回便签里那一段（一步撤销）。便签关了、换了另一条便签、或者那一段的字已经改了给 false（只复制）
    func replace(with translated: String) -> Bool {
      guard let view, view.window != nil, view.identifier == identifier else { return false }
      let text = TranslateCoordinator.rewrap(translated, like: plain)
      return view.replaceIfUnchanged(range, original: raw, with: text)
    }
  }

  /// 某个便签正文框里选中的一段（`noteSelection()` 拿 key 窗口那个；单测直接给视图）。
  /// 没选字、选的是空白给 nil
  static func noteSelection(in view: NoteTextView) -> NoteSelection? {
    guard view.window != nil, let storage = view.textStorage else { return nil }
    let range = view.selectedRange()
    guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
    let raw = storage.mutableString.substring(with: range)
    guard let plain = view.plainText(in: range),
      !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return NoteSelection(
      view: view, identifier: view.identifier, range: range, raw: raw, plain: plain)
  }

  /// key 窗口的第一响应者是便签正文、且有选中的字时，把它读出来（不动剪贴板、不碰前台 App）
  private func noteSelection() -> NoteSelection? {
    guard let view = NSApp.keyWindow?.firstResponder as? NoteTextView else { return nil }
    return Self.noteSelection(in: view)
  }

  /// 划词翻译：取词完成前绝不显示浮窗（先显示会取消原 App 的选区）。自家浮层是 key 时先收起，
  /// 否则 AX 读到的、⌘C 发到的都是自己。**key 窗口的第一响应者是便签正文**时直接读便签自己的选区（第 8 批 R13）
  func selectionTranslate() {
    // 截图框选中不划词：取词结束时显示的浮窗会被遮罩盖住、还抢走遮罩的 key（被它拦下的响一声，E3）
    guard !isReadingSelection, !isCapturing else {
      if isCapturing { NSSound.beep() }
      return
    }
    // 便签里划的词：直接读便签自己的选区，不走 AX、不发 ⌘C；没有选中字就当没取到（不去读后面的 App）
    let note = noteSelection()
    let noteFocused = NSApp.keyWindow?.firstResponder is NoteTextView
    isReadingSelection = true
    // 本 App 从不激活：此刻的前台就是取词的 App（「替换原文」只粘回它）
    let sourceApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if builtClipboardPanel?.isKeyWindow == true { builtClipboardPanel?.hide() }
    if builtLauncherPanel?.isKeyWindow == true { builtLauncherPanel?.hide() }
    launchpad.close(animated: false)
    if noteCapture?.panel.isKeyWindow == true { noteCapture?.panel.hide() }
    statusPicker.panel?.hide()
    if translatePanel.isKeyWindow { translatePanel.orderOut(nil) }
    // 指针停在缩略图 / 晾衣绳上、它们拿着键盘：还掉，不然合成的 ⌘C 落到卡片上、拷的是截图（第五轮体检 A3 评审 2）
    HoverKeyPanel.releaseAll()
    Task {
      defer { isReadingSelection = false }
      if let note {
        coordinator.translate(note.plain)
        coordinator.replaceSource = TranslateCoordinator.ReplaceSource(
          text: note.plain, pid: nil, note: { note.replace(with: $0) })
      } else if noteFocused {
        // 便签正文里没有选中的字：和「没取到选中的文字」一样，不去读后面那个 App
        coordinator.beginInput(missedSelection: true)
        Island.announce("没取到选中的文字，可以直接输入或粘贴")
      } else if let text = await SelectionReader.read(pausing: watcher) {
        coordinator.translate(text, selectedIn: sourceApp)
      } else if !Permissions.isAccessibilityTrusted {
        coordinator.showNotice(String(localized: "划词翻译需要「辅助功能」授权"), permission: .accessibility)
        Permissions.requestAccessibility()
      } else {
        // 没有选中文字：当输入翻译用，占位说清楚是没取到（体检 A16），VoiceOver 同一句
        coordinator.beginInput(missedSelection: true)
        Island.announce("没取到选中的文字，可以直接输入或粘贴")
      }
      presentTranslate()
    }
  }

  /// 浮窗「替换原文」（划词来的会话）：收起浮窗 → 写剪贴板 → ⌘V。浮窗从不激活本 App，前台一直是原 App，
  /// 选区还在，粘贴就替换掉它。前台已经换了（浮窗固定着、用户点了别的 App）或没有辅助功能授权时只复制
  func replaceOriginal() {
    guard let source = coordinator.replaceSource, let result = coordinator.primaryResult?.text
    else { return NSSound.beep() }
    let text = TranslateCoordinator.rewrap(result, like: source.text)
    // 便签里划的词：换回那个文本视图（一步撤销），不碰剪贴板、不看前台是哪个 App
    if let note = source.note {
      builtTranslatePanel?.hide()
      guard note(text) else {
        Paster.write(string: text, record: true)
        return island.show(
          "已复制译文", detail: "便签里的原文已经改了，没有替换", tone: .info, symbol: "doc.on.doc")
      }
      return island.show("已替换为译文", detail: "\(Island.excerpt(text))")
    }
    guard let pid = source.pid else {
      Paster.write(string: text, record: true)
      return island.show("已复制译文", tone: .info, symbol: "doc.on.doc")
    }
    // 写进去的译文是新内容，三条路都记进剪贴板历史（mac-native §5）
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      Paster.write(string: text, record: true)
      return island.show(
        "已复制译文", detail: "前台已不是取词的 App，没有替换", tone: .info, symbol: "doc.on.doc")
    }
    guard Permissions.isAccessibilityTrusted else {
      Paster.write(string: text, record: true)
      island.show(
        "已复制译文", detail: "授权辅助功能后才能直接替换", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return Permissions.requestAccessibility()
    }
    builtTranslatePanel?.hide()
    Paster.write(string: text, record: true)
    _ = Paster.pasteToFrontmost()
  }

  /// 划词翻译并替换（静默，对标 Bob 1.18）：取词 → 第一个服务翻译（等完整结果）→ 粘回替换选区；
  /// 不开浮窗，用轻提示报进度和结果；翻译期间再按一次热键取消。默认不设快捷键。
  /// 等结果的几秒里前台换了 App、或自家浮层成了 key，就只复制不粘（免得粘进别处）
  func translateAndReplace() {
    if let replaceTask {
      replaceTask.cancel()
      self.replaceTask = nil
      return island.show("已取消划词翻译并替换", tone: .info, symbol: "xmark.circle.fill")
    }
    guard !isReadingSelection, !isCapturing else {
      if isCapturing { NSSound.beep() }  // 被「正在截图」拦下的响一声（E3）
      return
    }
    // 便签里划的词：直接读便签自己的选区（R13），不要辅助功能授权、也不去读后面的 App
    let note = noteSelection()
    let noteFocused = NSApp.keyWindow?.firstResponder is NoteTextView
    if note == nil, noteFocused {
      return island.show("没有选中文字", tone: .warning)
    }
    guard note != nil || Permissions.isAccessibilityTrusted else {
      island.show(
        "需要「辅助功能」授权", detail: "划词翻译并替换要用", tone: .warning,
        actions: [.settings(for: .accessibility)])
      return Permissions.requestAccessibility()
    }
    let sourceApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    isReadingSelection = true
    // 和划词翻译一样：自家浮层是 key 时先收起，否则读到的、粘贴进去的都是自己。翻译浮窗只 orderOut
    // （hide 的 onHide 会把 key 还给别的浮层）：没固定就顺手作废它的请求，固定着的替换完再露出来
    let pinned = UserDefaults.standard.bool(forKey: Prefs.floatingPinned)
    let restoresPanel = translatePanel.isKeyWindow && pinned
    if builtClipboardPanel?.isKeyWindow == true { builtClipboardPanel?.hide() }
    if builtLauncherPanel?.isKeyWindow == true { builtLauncherPanel?.hide() }
    if noteCapture?.panel.isKeyWindow == true { noteCapture?.panel.hide() }
    statusPicker.panel?.hide()
    if translatePanel.isKeyWindow {
      translatePanel.orderOut(nil)
      if !pinned { coordinator.cancel() }
    }
    HoverKeyPanel.releaseAll()  // 同划词翻译：合成的 ⌘C、之后粘贴的 ⌘V 别落到卡片上
    let id = UUID()
    replaceID = id
    // 强持有 self（App 的代理，活到进程退出）：岛上「取消」「重试」也直接拿着它，岛收起时就放掉
    replaceTask = Task {
      defer {
        if replaceID == id { replaceTask = nil }
        if restoresPanel { translatePanel.present(makingKey: false, keepsPlace: true) }
      }
      let text: String?
      if let note {
        text = note.plain
        isReadingSelection = false
      } else {
        text = await SelectionReader.read(pausing: watcher)
        isReadingSelection = false  // 取完词就放开，等网络时不挡别的热键
      }
      // 取词期间被再按一次取消了：岛上已是「已取消」，别再用「没有选中文字」「翻译中…」盖掉它
      // （后者会一直挂到 60 秒兜底）
      guard !Task.isCancelled else { return }
      guard let text else { return island.show("没有选中文字", tone: .warning) }
      // 「取消」= 再按一次快捷键（还在翻才算：刚好翻完时点的不能又开一次）
      island.show(
        "翻译中…", detail: "再按一次快捷键取消", tone: .progress, symbol: "character.bubble.fill",
        actions: [.init("取消") { [self] in if replaceTask != nil { translateAndReplace() } }]
      )
      do {
        let result = TranslateCoordinator.rewrap(
          try await coordinator.translateOnce(text), like: text)
        guard !Task.isCancelled else { return }
        // 便签里划的词：换回那个文本视图（一步撤销）；便签关了 / 那段字改了只复制
        if let note {
          guard note.replace(with: result) else {
            Paster.write(string: result, record: true)
            return island.show(
              "已复制译文", detail: "便签里的原文已经改了，没有替换", tone: .info,
              symbol: "doc.on.doc")
          }
          return island.show("已替换为译文", detail: "\(Island.excerpt(result))")
        }
        Paster.write(string: result, record: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApp,
          NSApp.keyWindow == nil
        else {
          return island.show(
            "已复制译文", detail: "前台已不是取词的 App，没有替换", tone: .info, symbol: "doc.on.doc")
        }
        _ = Paster.pasteToFrontmost()
        island.show("已替换为译文", detail: "\(Island.excerpt(result))")
      } catch {
        guard !Task.isCancelled else { return }
        // 重试 = 再划一次：前台还是取词的 App（点岛不激活本 App），选区多半还在
        island.show(
          "翻译失败", detail: "\(error.localizedDescription)", tone: .error,
          actions: [.init("重试") { [self] in translateAndReplace() }])
      }
    }
  }

  /// 复制即译：只露出浮窗、不抢键盘（用户可能正在别的 App 里继续打字）。网址、路径、纯数字 / 符号、超长的和刚翻过的同一段
  /// 静默跳过（体检 A12 B20；第一语言的照翻成第二语言，2026-10-29）；通用剪贴板过来的 watcher 不交过来（第四轮体检 E17）；
  /// 这次的译文不自动复制（盖掉刚复制的原文，A19）
  func copyToTranslate(_ text: String) {
    let defaults = UserDefaults.standard
    // 状态屏里不弹：浮窗会在面板底下冒出来（透出样式看得见）
    guard Feature.translate.isOn, defaults.bool(forKey: Prefs.translateCopyToTranslate),
      !statusScreen.isActive
    else { return }
    let (first, second) = Lang.preferredPair
    guard
      TranslateCoordinator.worthTranslating(
        copied: text, translated: coordinator.translatedSource, first: first, second: second)
    else { return }
    coordinator.translate(text, fromCopy: true)
    presentTranslate(makingKey: false)
  }
}
