// AppDelegate 里便签的入口（第五轮体检 H1 从 AppDelegate.swift 拆出）：快速记一条、全部便签窗口、新建便签、屏幕边缘那叠。

import AppKit
import SwiftUI

extension AppDelegate {
  // MARK: 便签的入口

  /// 便签这次用不了（库打不开时选了「这次先不用」、库是更新版本写的，noteStore 是 nil）：三个入口都不做事，说一声
  private func usableNotes() -> NoteStore? {
    if noteStore == nil { island.show("便签这次用不了", tone: .warning) }
    return noteStore
  }

  /// 快速记一条（默认 ⌥N）：和启动器、剪贴板面板同位置同宽，只开一个——呼出它时收起那两块（和选状态的面板），
  /// 呼出那两块时收起它；再按一次 = 收起（草稿留着）
  func toggleNoteCapture() {
    guard let store = usableNotes() else { return }
    let capture = noteCapture ?? makeNoteCapture(store)
    noteCapture = capture
    if !(capture.panel.isVisible && capture.panel.isKeyWindow) {
      builtClipboardPanel?.hide()
      builtLauncherPanel?.hide()
      statusPicker.panel?.hide()
    }
    if !capture.panel.isVisible {
      capture.model.prepareForShow()
      capture.panel.setContentHeight(capture.model.height)
    }
    capture.panel.toggle()
  }

  private func makeNoteCapture(_ store: NoteStore) -> (panel: OverlayPanel, model: NoteCaptureModel)
  {
    // 草稿存在数据目录里（E2：不放偏好——偏好会被设置的导出 / 同步带走），建面板时读回
    let model = NoteCaptureModel(
      store: store, draftURL: dataDirectory.appending(path: NoteCaptureModel.draftName))
    let panel = OverlayPanel(
      size: NSSize(width: Style.listPanelWidth, height: model.height), topAnchored: true,
      // 没有固定：点外面就收起（草稿留着）
      autoHide: .clickOutside, isPinned: { false }, content: NoteCaptureView(model: model))
    panel.keyEquivalentHandler = { [unowned model] in model.handleKeyEquivalent($0) }
    panel.onHide = { [unowned model] in model.didHide() }
    panel.squeezesIn = { Self.squeezesIn() }
    model.hidePanel = { [unowned panel] in panel.hide() }
    model.dismissPanel = { [unowned panel] in panel.dismiss() }
    model.resize = { [unowned panel] in panel.setContentHeight($0, animated: true) }
    model.island = island
    // 岛上的「恢复」（E2）：重新呼出；「打开」（U6）：那叠开着就在那叠里打开这一条，关着在全部便签窗口里打开
    model.reopen = { [unowned self, unowned panel] in
      if !(panel.isVisible && panel.isKeyWindow) { toggleNoteCapture() }
    }
    // 这一下可能是很久以后在「那一张」里点的：那条已经归档 / 删掉了就去全部便签窗口里它在的地方（没了就只打开窗口）
    model.openNote = { [unowned self] id in
      if store.note(id)?.isActive == true, noteEdge?.open(id) == true { return }
      showNotes(revealing: id)
    }
    return (panel, model)
  }

  /// 全部便签窗口（普通窗口，打开方式同设置窗：先收起浮层）。creating：先建一条空的、选中、焦点进正文（「新建便签」
  /// 在屏幕边缘那叠开不了时走这里）；revealing：选中这一条（从那叠「在全部便签里打开」）
  func showNotes(creating: Bool = false, revealing id: String? = nil) {
    guard let store = usableNotes() else { return }
    hidePanels()
    let window = notesWindow ?? makeNotesWindow(store)
    notesWindow = window
    window.show()
    // 打开全部便签窗口时合一轮：看到的是别的 Mac 的最新样子
    noteSyncer?.syncNow()
    if creating { window.model.create() }
    if let id { window.model.reveal(id) }
  }

  /// 「新建便签」（全局动作、菜单栏、启动器、药丸的右键菜单）：屏幕边缘那叠开着（总开关开）就建一条、在鼠标所在屏的
  /// 那叠里打开；那边开不了（总开关关着、哪块屏都放不了）照第 2 批在全部便签窗口里新建
  func newNote() {
    guard usableNotes() != nil else { return }
    if noteEdge?.openNew() != true { showNotes(creating: true) }
  }
  /// 「屏幕边缘的便签」（X16）：那叠扇出来、键盘给它；已经展开着就收回。屏幕边缘关着、还没有便签时岛上说
  func summonNoteDeck() {
    guard usableNotes() != nil, let noteEdge else { return }
    switch noteEdge.summon() {
    case .done: break
    case .disabled:
      island.show(
        "屏幕边缘的便签关着", detail: "到 设置 › 便签 › 屏幕边缘 里打开", tone: .info,
        actions: [.init("打开设置", opens: true) { [unowned self] in showSettings(.notesDeck) }])
    case .empty:
      island.show(
        "还没有便签", detail: "记下第一条，屏幕边缘就会出现", tone: .info,
        actions: [.init("新建便签") { [unowned self] in newNote() }])
    }
  }

  private func makeNotesWindow(_ store: NoteStore) -> NotesWindow {
    let window = NotesWindow(model: notesModel ?? makeNotesModel(store))
    window.onClose = { [unowned self] in idleReclaim.schedule() }
    return window
  }

  private func makeNotesModel(_ store: NoteStore) -> NotesWindowModel {
    let model = NotesWindowModel(store: store, defaults: .standard)
    model.island = island
    // 工具栏 / 右键菜单的「浮在屏幕上」：和屏幕边缘那叠共用同一份浮动便签（同时最多浮几张，NoteFloats）
    model.floats = noteEdge?.floats
    model.toggleFloat = { [unowned self] in noteEdge?.floats.toggle($0) }
    // ⌘,、工具栏的「便签设置」：落在设置的「便签」页
    model.showSettings = { [unowned self] in showSettings(.notesFontSize) }
    notesModel = model
    return model
  }
}
